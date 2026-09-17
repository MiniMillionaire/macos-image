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
	downloadChunkSize      = 4 << 20
	downloadSmallChunk     = 1 << 20
	downloadWorkers        = 4
	downloadRequestTimeout = 12 * time.Second
	maxChunkRequests       = 24
	maxStalledRequests     = 3
)

var ghcrRepositoryPattern = regexp.MustCompile(`\Aghcr\.io/[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+\z`)

type ociDownloader struct {
	client     *http.Client
	repository string
	mu         sync.Mutex
	token      string
	tokenTime  time.Time
}

func downloadOCI(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("download-oci", flag.ContinueOnError)
	repository := flags.String("repository", "", "Public GHCR repository")
	digest := flags.String("digest", "", "Pinned OCI manifest digest")
	layout := flags.String("layout", "", "New OCI layout directory")
	resume := flags.Bool("resume", false, "Reuse verified blobs in an existing OCI layout")
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
	transport.ForceAttemptHTTP2 = true
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
	if *resume {
		info, statErr := os.Lstat(*layout)
		if statErr != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("resume requires an existing layout directory")
		}
	} else {
		if err := os.Mkdir(*layout, 0700); err != nil {
			return err
		}
	}
	blobDir := filepath.Join(*layout, "blobs", "sha256")
	if err := os.MkdirAll(blobDir, 0700); err != nil {
		return err
	}
	for _, path := range []string{filepath.Join(*layout, "blobs"), blobDir} {
		info, err := os.Lstat(path)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("invalid OCI blob directory")
		}
	}
	entry, doc, err := d.manifest(ctx, *layout, *digest)
	if err != nil {
		return err
	}
	if err := d.blobs(ctx, *layout, append([]descriptor{doc.Config}, doc.Layers...), *resume); err != nil {
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
		return nil, fmt.Errorf("anonymous token: %w", err)
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
	resp, err := d.client.Do(req)
	if err != nil {
		var requestError *url.Error
		if errors.As(err, &requestError) {
			return nil, requestError.Err
		}
	}
	return resp, err
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
	file, err := os.CreateTemp(filepath.Dir(path), ".manifest-*")
	if err != nil {
		return descriptor{}, manifest{}, err
	}
	defer os.Remove(file.Name())
	if _, err := file.Write(data); err != nil {
		file.Close()
		return descriptor{}, manifest{}, err
	}
	if err := file.Close(); err != nil {
		return descriptor{}, manifest{}, err
	}
	entry := descriptor{MediaType: manifestType, Digest: digest, Size: int64(len(data)),
		Annotations: map[string]string{"org.opencontainers.image.ref.name": "image"}}
	if err := verifyFile(file.Name(), strings.TrimPrefix(digest, "sha256:"), entry.Size); err != nil {
		return descriptor{}, manifest{}, err
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return descriptor{}, manifest{}, err
	}
	return entry, doc, nil
}

func (d *ociDownloader) blobs(ctx context.Context, layout string, entries []descriptor, resume bool) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan descriptor)
	var workers sync.WaitGroup
	var once sync.Once
	var first error
	for range downloadWorkers {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for entry := range jobs {
				if err := d.blob(ctx, layout, entry, resume); err != nil {
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

func (d *ociDownloader) blob(ctx context.Context, layout string, entry descriptor, resume bool) error {
	path, err := blobPath(layout, entry.Digest)
	if err != nil {
		return err
	}
	if resume {
		if info, err := os.Lstat(path); err == nil {
			if !info.Mode().IsRegular() {
				return fmt.Errorf("cached blob is not a regular file: %s", entry.Digest)
			}
			if err := verifyFile(path, strings.TrimPrefix(entry.Digest, "sha256:"), entry.Size); err != nil {
				return fmt.Errorf("cached blob %s: %w", entry.Digest, err)
			}
			fmt.Fprintf(os.Stderr, "Reused %s (%d bytes)\n", entry.Digest, entry.Size)
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
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
	position := 0
	fragmented := false
	stalled := 0
	for attempt := 0; attempt < maxChunkRequests && position < len(buffer); attempt++ {
		length := len(buffer) - position
		if fragmented {
			length = min(length, downloadSmallChunk)
		}
		from := start + int64(position)
		end := from + int64(length) - 1
		wanted := fmt.Sprintf("bytes %d-%d/%d", from, end, entry.Size)
		requestCtx, cancel := context.WithTimeout(ctx, downloadRequestTimeout)
		resp, err := d.request(requestCtx, "/blobs/"+entry.Digest, fmt.Sprintf("bytes=%d-%d", from, end))
		readBytes := 0
		var last error
		if err == nil {
			if resp.StatusCode == http.StatusUnauthorized {
				d.expireAuthorization()
			}
			if resp.StatusCode != http.StatusPartialContent || resp.Header.Get("Content-Range") != wanted ||
				(resp.ContentLength >= 0 && resp.ContentLength != int64(length)) {
				last = fmt.Errorf("unexpected blob response: HTTP %d, range %q, length %d", resp.StatusCode,
					resp.Header.Get("Content-Range"), resp.ContentLength)
			} else {
				var readErr error
				readBytes, readErr = io.ReadFull(resp.Body, buffer[position:position+length])
				if readBytes > 0 {
					if _, err := file.WriteAt(buffer[position:position+readBytes], from); err != nil {
						_ = resp.Body.Close()
						cancel()
						return fmt.Errorf("write range at byte %d: %w", from, err)
					}
					position += readBytes
				}
				if readErr != nil {
					last = fmt.Errorf("read range body after %d/%d bytes: %w", readBytes, length, readErr)
				}
			}
			_ = resp.Body.Close()
		} else {
			last = fmt.Errorf("request range: %w", err)
		}
		cancel()
		if last == nil {
			stalled = 0
			continue
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !fragmented {
			fmt.Fprintf(os.Stderr, "Resuming %s after byte %d: %v\n", entry.Digest, from+int64(readBytes), last)
		}
		fragmented = true
		d.expireAuthorization()
		if readBytes == 0 {
			stalled++
		} else {
			stalled = 0
		}
		if stalled >= maxStalledRequests {
			return fmt.Errorf("range stalled at byte %d: %w", from, last)
		}
		if readBytes == 0 {
			select {
			case <-time.After(time.Duration(stalled) * time.Second):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	if position != len(buffer) {
		return fmt.Errorf("range request limit reached at byte %d", start+int64(position))
	}
	return nil
}
