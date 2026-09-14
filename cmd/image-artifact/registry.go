package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type registry struct {
	root     string
	host     string
	writable bool
	server   *http.Server
	mu       sync.Mutex
	manifest descriptor
}

func newRegistry(root string, writable bool) (*registry, error) {
	r := &registry{root: root, writable: writable}
	if writable {
		for _, directory := range []string{"blobs/sha256", ".uploads"} {
			if err := os.MkdirAll(filepath.Join(root, directory), 0700); err != nil {
				return nil, err
			}
		}
	} else {
		var idx index
		if err := jsonFile(filepath.Join(root, "index.json"), &idx); err != nil {
			return nil, err
		}
		if len(idx.Manifests) != 1 {
			return nil, errors.New("expected one OCI manifest")
		}
		r.manifest = idx.Manifests[0]
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	r.host = listener.Addr().String()
	r.server = &http.Server{Handler: r, ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout: 5 * time.Minute, WriteTimeout: 15 * time.Minute, IdleTimeout: 30 * time.Second,
		MaxHeaderBytes: 16 << 10}
	go func() { _ = r.server.Serve(listener) }()
	return r, nil
}

func (r *registry) reference() string { return r.host + "/base/image" }
func (r *registry) close()            { _ = r.server.Close() }

func (r *registry) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Docker-Distribution-API-Version", "registry/2.0")
	if req.URL.Path == "/v2/" && (req.Method == "GET" || req.Method == "HEAD") {
		w.WriteHeader(http.StatusOK)
		return
	}
	if req.Method == "GET" || req.Method == "HEAD" {
		r.read(w, req)
		return
	}
	if !r.writable {
		http.Error(w, "read-only registry", http.StatusMethodNotAllowed)
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.write(w, req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
	}
}

func (r *registry) read(w http.ResponseWriter, req *http.Request) {
	var digest string
	kind := "application/octet-stream"
	path := req.URL.Path
	if value, ok := strings.CutPrefix(path, "/v2/base/image/blobs/"); ok {
		digest = value
	} else if value, ok := strings.CutPrefix(path, "/v2/base/image/manifests/"); ok {
		r.mu.Lock()
		entry := r.manifest
		r.mu.Unlock()
		if value != "image" && value != entry.Digest {
			http.NotFound(w, req)
			return
		}
		digest, kind = entry.Digest, manifestType
	}
	filePath, err := blobPath(r.root, digest)
	if err != nil {
		http.NotFound(w, req)
		return
	}
	if _, err := regular(filePath); err != nil {
		http.NotFound(w, req)
		return
	}
	file, err := os.Open(filePath)
	if err != nil {
		http.NotFound(w, req)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", kind)
	w.Header().Set("Docker-Content-Digest", digest)
	http.ServeContent(w, req, "", time.Time{}, file)
}

func (r *registry) write(w http.ResponseWriter, req *http.Request) error {
	const uploads = "/v2/base/image/blobs/uploads/"
	if req.Method == "POST" && req.URL.Path == uploads {
		id := make([]byte, 16)
		if _, err := rand.Read(id); err != nil {
			return err
		}
		name := hex.EncodeToString(id)
		file, err := os.OpenFile(filepath.Join(r.root, ".uploads", name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
		w.Header().Set("Location", uploads+name)
		w.WriteHeader(http.StatusAccepted)
		return nil
	}
	if id, ok := strings.CutPrefix(req.URL.Path, uploads); ok && (req.Method == "PATCH" || req.Method == "PUT") {
		if len(id) != 32 || strings.ContainsAny(id, "/.\\") {
			return errors.New("invalid upload ID")
		}
		if _, err := hex.DecodeString(id); err != nil {
			return err
		}
		path := filepath.Join(r.root, ".uploads", id)
		if _, err := regular(path); err != nil {
			return err
		}
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(file, http.MaxBytesReader(w, req.Body, 64<<20))
		if err := errors.Join(copyErr, file.Close()); err != nil {
			return err
		}
		if req.Method == "PATCH" {
			w.Header().Set("Location", req.URL.Path)
			w.WriteHeader(http.StatusAccepted)
			return nil
		}
		hash, _, err := checksum(path)
		if err != nil {
			return err
		}
		digest := "sha256:" + hash
		if digest != req.URL.Query().Get("digest") {
			return errors.New("uploaded blob digest mismatch")
		}
		destination, _ := blobPath(r.root, digest)
		if err := os.Rename(path, destination); err != nil {
			return err
		}
		w.Header().Set("Location", "/v2/base/image/blobs/"+digest)
		w.Header().Set("Docker-Content-Digest", digest)
		w.WriteHeader(http.StatusCreated)
		return nil
	}
	if req.Method == "PUT" && req.URL.Path == "/v2/base/image/manifests/image" {
		body, err := io.ReadAll(http.MaxBytesReader(w, req.Body, 4<<20))
		if err != nil {
			return err
		}
		hash := sha256.Sum256(body)
		digest := "sha256:" + hex.EncodeToString(hash[:])
		path, _ := blobPath(r.root, digest)
		if err := os.WriteFile(path, body, 0600); err != nil {
			return err
		}
		r.manifest = descriptor{MediaType: manifestType, Digest: digest, Size: int64(len(body)),
			Annotations: map[string]string{"org.opencontainers.image.ref.name": "image"}}
		w.Header().Set("Docker-Content-Digest", digest)
		w.WriteHeader(http.StatusCreated)
		return nil
	}
	return fmt.Errorf("unsupported registry request: %s %s", req.Method, req.URL.Path)
}

func (r *registry) finish() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.manifest.Digest == "" {
		return errors.New("Tart did not upload a manifest")
	}
	if err := saveJSON(filepath.Join(r.root, "oci-layout"), map[string]string{"imageLayoutVersion": "1.0.0"}); err != nil {
		return err
	}
	if err := saveJSON(filepath.Join(r.root, "index.json"), index{SchemaVersion: 2, Manifests: []descriptor{r.manifest}}); err != nil {
		return err
	}
	return os.RemoveAll(filepath.Join(r.root, ".uploads"))
}
