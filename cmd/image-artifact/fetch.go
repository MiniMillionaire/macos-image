package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

var hashPattern = regexp.MustCompile(`\A[0-9a-f]{64}\z`)

func regular(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("not a regular file: %s", path)
	}
	return info, nil
}

func checksum(path string) (string, int64, error) {
	if _, err := regular(path); err != nil {
		return "", 0, err
	}
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	return hex.EncodeToString(hash.Sum(nil)), size, err
}

func verifyFile(path, expected string, size int64) error {
	hash, actual, err := checksum(path)
	if err != nil {
		return err
	}
	if actual != size || hash != expected {
		return fmt.Errorf("size or SHA-256 mismatch: %s", path)
	}
	return nil
}

func fetch(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("fetch", flag.ContinueOnError)
	source := flags.String("url", "", "HTTPS download URL")
	output := flags.String("output", "", "Verified destination file")
	hash := flags.String("sha256", "", "Expected SHA-256")
	size := flags.Int64("size", 0, "Expected size in bytes")
	ca := flags.String("ca-file", "", "PEM certificate authority bundle")
	seconds := flags.Int("timeout", 2700, "Maximum download duration in seconds")
	if err := flags.Parse(args); err != nil {
		return err
	}
	u, err := url.Parse(*source)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil ||
		*output == "" || *size <= 0 || *seconds <= 0 || !hashPattern.MatchString(*hash) {
		return errors.New("fetch requires an HTTPS URL, output, size and SHA-256")
	}
	if _, err := os.Lstat(*output); err == nil {
		return verifyFile(*output, *hash, *size)
	} else if !os.IsNotExist(err) {
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
	transport.ResponseHeaderTimeout = 30 * time.Second
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 || req.URL.Scheme != "https" || req.URL.User != nil {
			return errors.New("unsafe or excessive download redirects")
		}
		return nil
	}}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(*seconds)*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, *source, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download returned HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != *size {
		return errors.New("download Content-Length does not match the pinned size")
	}
	if err := os.MkdirAll(filepath.Dir(*output), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(*output), ".download-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	digest := sha256.New()
	n, err := io.Copy(io.MultiWriter(file, digest), io.LimitReader(resp.Body, *size+1))
	if err != nil {
		return err
	}
	if n != *size || hex.EncodeToString(digest.Sum(nil)) != *hash {
		return errors.New("download size or SHA-256 does not match the pinned input")
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Link(file.Name(), *output)
}
