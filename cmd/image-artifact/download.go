package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	downloadChunkSize  = 8 << 20
	downloadSmallChunk = 1 << 20
)

var ghcrRepositoryPattern = regexp.MustCompile(`\Aghcr\.io/[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+\z`)

type ociDownloader struct {
	client     *http.Client
	repository string
	mu         sync.Mutex
	token      string
	tokenTime  time.Time
}

func downloadOCI(ctx context.Context, args []string) (err error) {
	flags := flag.NewFlagSet("download-oci", flag.ContinueOnError)
	repository := flags.String("repository", "", "Public GHCR repository")
	digest := flags.String("digest", "", "Pinned OCI manifest digest")
	layout := flags.String("layout", "", "New OCI layout directory")
	ca := flags.String("ca-file", "", "PEM certificate authority bundle")
	seconds := flags.Int("timeout", 4800, "Maximum download duration in seconds")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if !ghcrRepositoryPattern.MatchString(*repository) || *layout == "" || *seconds <= 0 {
		return errors.New("download-oci requires a public GHCR repository, digest, layout, and positive timeout")
	}
	if _, err := blobPath(*layout, *digest); err != nil {
		return err
	}
	pem, err := os.ReadFile(*ca)
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		return errors.New("CA file contains no certificates")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	transport.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
	transport.ForceAttemptHTTP2 = false
	transport.ResponseHeaderTimeout = 30 * time.Second
	defer transport.CloseIdleConnections()
	d := &ociDownloader{repository: strings.TrimPrefix(*repository, "ghcr.io/"), client: &http.Client{
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 || req.URL.Scheme != "https" || req.URL.User != nil ||
				(req.URL.Hostname() != "ghcr.io" && req.URL.Hostname() != "pkg-containers.githubusercontent.com") {
				return errors.New("unsafe or excessive registry redirect")
			}
			return nil
		},
	}}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(*seconds)*time.Second)
	defer cancel()
	if err := os.Mkdir(*layout, 0700); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(*layout)
		}
	}()
	if err := os.MkdirAll(filepath.Join(*layout, "blobs", "sha256"), 0700); err != nil {
		return err
	}
	entry, doc, err := d.manifest(ctx, *layout, *digest)
	if err != nil {
		return err
	}
	if err := d.blobs(ctx, *layout, append([]descriptor{doc.Config}, doc.Layers...)); err != nil {
		return err
	}
	if err := saveJSON(filepath.Join(*layout, "oci-layout"), map[string]string{"imageLayoutVersion": "1.0.0"}); err != nil {
		return err
	}
	if err := saveJSON(filepath.Join(*layout, "index.json"), index{SchemaVersion: 2, Manifests: []descriptor{entry}}); err != nil {
		return err
	}
	_, _, err = inspect(*layout)
	return err
}

func (d *ociDownloader) authorization(ctx context.Context) (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.token != "" && time.Since(d.tokenTime) < time.Minute {
		return d.token, nil
	}
	u := "https://ghcr.io/token?service=ghcr.io&scope=" + url.QueryEscape("repository:"+d.repository+":pull")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", err
	}
	requestCtx, cancel := context.WithTimeout(req.Context(), 30*time.Second)
	defer cancel()
	resp, err := d.client.Do(req.WithContext(requestCtx))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GHCR token returned HTTP %d", resp.StatusCode)
	}
	var token struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&token); err != nil {
		return "", err
	}
	if token.Token == "" {
		return "", errors.New("GHCR returned an empty anonymous token")
	}
	d.token, d.tokenTime = token.Token, time.Now()
	return d.token, nil
}

func (d *ociDownloader) expireAuthorization() {
	d.mu.Lock()
	d.tokenTime = time.Time{}
	d.mu.Unlock()
}

func (d *ociDownloader) request(ctx context.Context, path, rangeHeader string) (*http.Response, error) {
	token, err := d.authorization(ctx)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://ghcr.io/v2/"+d.repository+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if rangeHeader != "" {
		req.Header.Set("Range", rangeHeader)
	} else {
		req.Header.Set("Accept", manifestType)
	}
	return d.client.Do(req)
}

func (d *ociDownloader) manifest(ctx context.Context, layout, digest string) (descriptor, manifest, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	resp, err := d.request(requestCtx, "/manifests/"+digest, "")
	if err != nil {
		return descriptor{}, manifest{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return descriptor{}, manifest{}, fmt.Errorf("GHCR manifest returned HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
	if err != nil {
		return descriptor{}, manifest{}, err
	}
	if len(data) == 0 || len(data) > 4<<20 {
		return descriptor{}, manifest{}, errors.New("invalid OCI manifest size")
	}
	var doc manifest
	if err := json.Unmarshal(data, &doc); err != nil {
		return descriptor{}, manifest{}, err
	}
	if doc.SchemaVersion != 2 || len(doc.Layers) == 0 {
		return descriptor{}, manifest{}, errors.New("empty or invalid OCI manifest")
	}
	path, _ := blobPath(layout, digest)
	if err := os.WriteFile(path, data, 0600); err != nil {
		return descriptor{}, manifest{}, err
	}
	entry := descriptor{MediaType: manifestType, Digest: digest, Size: int64(len(data)),
		Annotations: map[string]string{"org.opencontainers.image.ref.name": "image"}}
	if err := verifyFile(path, strings.TrimPrefix(digest, "sha256:"), entry.Size); err != nil {
		return descriptor{}, manifest{}, err
	}
	return entry, doc, nil
}

func (d *ociDownloader) blobs(ctx context.Context, layout string, entries []descriptor) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan descriptor)
	var workers sync.WaitGroup
	var once sync.Once
	var first error
	for range 6 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for entry := range jobs {
				if err := d.blob(ctx, layout, entry); err != nil {
					once.Do(func() { first = err; cancel() })
					return
				}
			}
		}()
	}
	seen := make(map[string]int64)
send:
	for _, entry := range entries {
		if entry.Size <= 0 {
			once.Do(func() { first = errors.New("invalid OCI blob size"); cancel() })
			break
		}
		if size, exists := seen[entry.Digest]; exists {
			if size != entry.Size {
				once.Do(func() { first = errors.New("conflicting OCI blob sizes"); cancel() })
				break
			}
			continue
		}
		seen[entry.Digest] = entry.Size
		select {
		case jobs <- entry:
		case <-ctx.Done():
			break send
		}
	}
	close(jobs)
	workers.Wait()
	if first != nil {
		return first
	}
	return ctx.Err()
}

func (d *ociDownloader) blob(ctx context.Context, layout string, entry descriptor) error {
	path, err := blobPath(layout, entry.Digest)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".blob-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	buffer := make([]byte, downloadChunkSize)
	for start := int64(0); start < entry.Size; start += downloadChunkSize {
		length := min(int64(downloadChunkSize), entry.Size-start)
		if err := d.chunk(ctx, file, entry, start, buffer[:length]); err != nil {
			return fmt.Errorf("download %s at byte %d: %w", entry.Digest, start, err)
		}
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := verifyFile(file.Name(), strings.TrimPrefix(entry.Digest, "sha256:"), entry.Size); err != nil {
		return err
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Downloaded %s (%d bytes)\n", entry.Digest, entry.Size)
	return nil
}

func (d *ociDownloader) chunk(ctx context.Context, file *os.File, entry descriptor, start int64, buffer []byte) error {
	end := start + int64(len(buffer)) - 1
	wanted := fmt.Sprintf("bytes %d-%d/%d", start, end, entry.Size)
	var last error
	for attempt := range 2 {
		requestCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
		resp, err := d.request(requestCtx, "/blobs/"+entry.Digest, fmt.Sprintf("bytes=%d-%d", start, end))
		if err == nil {
			if resp.StatusCode == http.StatusUnauthorized {
				d.expireAuthorization()
			}
			if resp.StatusCode != http.StatusPartialContent || resp.Header.Get("Content-Range") != wanted ||
				(resp.ContentLength >= 0 && resp.ContentLength != int64(len(buffer))) {
				last = fmt.Errorf("unexpected blob response: HTTP %d, range %q, length %d", resp.StatusCode,
					resp.Header.Get("Content-Range"), resp.ContentLength)
			} else {
				_, last = io.ReadFull(resp.Body, buffer)
				if last == nil {
					_, last = file.WriteAt(buffer, start)
				}
			}
			_ = resp.Body.Close()
		} else {
			last = err
		}
		cancel()
		if last == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		d.expireAuthorization()
		if attempt < 1 {
			select {
			case <-time.After(time.Duration(attempt+1) * time.Second):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	if len(buffer) > downloadSmallChunk {
		for offset := 0; offset < len(buffer); offset += downloadSmallChunk {
			limit := min(offset+downloadSmallChunk, len(buffer))
			if err := d.chunk(ctx, file, entry, start+int64(offset), buffer[offset:limit]); err != nil {
				return err
			}
		}
		return nil
	}
	return last
}
