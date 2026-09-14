package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const manifestType = "application/vnd.oci.image.manifest.v1+json"

type descriptor struct {
	MediaType   string            `json:"mediaType"`
	Digest      string            `json:"digest"`
	Size        int64             `json:"size"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

type manifest struct {
	SchemaVersion int          `json:"schemaVersion"`
	Config        descriptor   `json:"config"`
	Layers        []descriptor `json:"layers"`
}

type index struct {
	SchemaVersion int          `json:"schemaVersion"`
	Manifests     []descriptor `json:"manifests"`
}

func writeJSON(out io.Writer, value any) error {
	encoder := json.NewEncoder(out)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func jsonFile(path string, value any) error {
	info, err := regular(path)
	if err != nil {
		return err
	}
	if info.Size() > 4<<20 {
		return fmt.Errorf("JSON file exceeds 4 MiB: %s", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, value)
}

func saveJSON(path string, value any) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	err = writeJSON(file, value)
	return errors.Join(err, file.Close())
}

func blobPath(layout, digest string) (string, error) {
	hash, ok := strings.CutPrefix(digest, "sha256:")
	if !ok || !hashPattern.MatchString(hash) {
		return "", fmt.Errorf("invalid OCI digest: %s", digest)
	}
	return filepath.Join(layout, "blobs", "sha256", hash), nil
}

func inspect(layout string) (descriptor, map[string]any, error) {
	var format struct {
		Version string `json:"imageLayoutVersion"`
	}
	var idx index
	if err := jsonFile(filepath.Join(layout, "oci-layout"), &format); err != nil {
		return descriptor{}, nil, err
	}
	if err := jsonFile(filepath.Join(layout, "index.json"), &idx); err != nil {
		return descriptor{}, nil, err
	}
	if format.Version != "1.0.0" || idx.SchemaVersion != 2 || len(idx.Manifests) != 1 ||
		idx.Manifests[0].Annotations["org.opencontainers.image.ref.name"] != "image" {
		return descriptor{}, nil, errors.New("expected one OCI image named image")
	}
	entry := idx.Manifests[0]
	if entry.MediaType != manifestType {
		return descriptor{}, nil, errors.New("expected an OCI image manifest")
	}
	path, err := blobPath(layout, entry.Digest)
	if err != nil {
		return descriptor{}, nil, err
	}
	if err := verifyFile(path, strings.TrimPrefix(entry.Digest, "sha256:"), entry.Size); err != nil {
		return descriptor{}, nil, err
	}
	var doc manifest
	if err := jsonFile(path, &doc); err != nil {
		return descriptor{}, nil, err
	}
	if doc.SchemaVersion != 2 || len(doc.Layers) == 0 {
		return descriptor{}, nil, errors.New("empty or invalid image manifest")
	}
	seen := make(map[string]int64)
	var total int64
	for _, blob := range append([]descriptor{doc.Config}, doc.Layers...) {
		path, err := blobPath(layout, blob.Digest)
		if err != nil {
			return descriptor{}, nil, err
		}
		if blob.Size < 0 {
			return descriptor{}, nil, errors.New("negative OCI blob size")
		}
		if size, exists := seen[blob.Digest]; exists {
			if size != blob.Size {
				return descriptor{}, nil, errors.New("conflicting sizes for one OCI blob")
			}
		} else {
			if err := verifyFile(path, strings.TrimPrefix(blob.Digest, "sha256:"), blob.Size); err != nil {
				return descriptor{}, nil, err
			}
			seen[blob.Digest] = blob.Size
			total += blob.Size
		}
	}
	configPath, _ := blobPath(layout, doc.Config.Digest)
	var config struct {
		OS           string `json:"os"`
		Architecture string `json:"architecture"`
		Config       struct {
			Labels map[string]string `json:"Labels"`
		} `json:"config"`
	}
	if err := jsonFile(configPath, &config); err != nil {
		return descriptor{}, nil, err
	}
	if config.OS != "darwin" || config.Architecture != "arm64" {
		return descriptor{}, nil, errors.New("expected a darwin/arm64 image")
	}
	info := map[string]any{"manifest_digest": entry.Digest, "manifest_size": entry.Size, "blob_bytes": total}
	for key, label := range map[string]string{
		"revision": "org.opencontainers.image.revision",
		"source":   "org.opencontainers.image.source", "macos_version": "dev.macos-image.version",
		"macos_build": "dev.macos-image.build", "variant": "dev.macos-image.variant",
		"xcode_version": "dev.macos-image.xcode-version",
	} {
		info[key] = config.Config.Labels[label]
	}
	return entry, info, nil
}

func vmPath(name string) (string, error) {
	if !regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9._-]*\z`).MatchString(name) {
		return "", errors.New("invalid local VM name")
	}
	home := os.Getenv("TART_HOME")
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		home = filepath.Join(userHome, ".tart")
	}
	return filepath.Join(home, "vms", name), nil
}

func validateVM(ctx context.Context, path string) error {
	for _, name := range []string{"config.json", "disk.img", "nvram.bin"} {
		if _, err := regular(filepath.Join(path, name)); err != nil {
			return err
		}
	}
	var config map[string]any
	if err := jsonFile(filepath.Join(path, "config.json"), &config); err != nil {
		return err
	}
	if config["os"] != "darwin" || config["arch"] != "arm64" ||
		(config["diskFormat"] != nil && config["diskFormat"] != "raw") {
		return errors.New("expected a standalone darwin/arm64 raw VM")
	}
	for _, field := range []string{"hardwareModel", "ecid"} {
		value, _ := config[field].(string)
		decoded, err := base64.StdEncoding.DecodeString(value)
		if err != nil || len(decoded) == 0 {
			return fmt.Errorf("invalid VM %s", field)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "/usr/sbin/lsof", "-Fpc", "--", filepath.Join(path, "disk.img")).CombinedOutput()
	var exit *exec.ExitError
	if len(output) == 0 && errors.As(err, &exit) && exit.ExitCode() == 1 {
		return nil
	}
	if ctx.Err() != nil {
		return fmt.Errorf("check VM disk: %w", ctx.Err())
	}
	if err != nil {
		return fmt.Errorf("check VM disk: %w\n%s", err, strings.TrimSpace(string(output)))
	}
	return fmt.Errorf("VM disk is open:\n%s", strings.TrimSpace(string(output)))
}

func tartEnvironment(host string) []string {
	var env []string
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(key, "TART_REGISTRY_") || key == "GH_TOKEN" || key == "GITHUB_TOKEN" || key == "TART_NO_AUTO_PRUNE" {
			continue
		}
		env = append(env, entry)
	}
	return append(env, "TART_REGISTRY_HOSTNAME="+host, "TART_REGISTRY_USERNAME=unused",
		"TART_REGISTRY_PASSWORD=unused", "TART_NO_AUTO_PRUNE=1")
}

func exportImage(ctx context.Context, args []string) (err error) {
	flags := flag.NewFlagSet("export", flag.ContinueOnError)
	vm := flags.String("vm", "", "Stopped local VM")
	layout := flags.String("layout", "", "New OCI layout directory")
	revision := flags.String("revision", "", "Source commit SHA")
	osVersion := flags.String("macos-version", "", "macOS version")
	build := flags.String("macos-build", "", "Apple build")
	variant := flags.String("variant", "", "Image variant")
	source := flags.String("source", "", "Source repository URL")
	xcode := flags.String("xcode-version", "", "Xcode version")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *layout == "" || !regexp.MustCompile(`\A[0-9a-f]{40}\z`).MatchString(*revision) ||
		*osVersion == "" || *build == "" || *source == "" ||
		(*variant != "vanilla" && *variant != "base" && *variant != "xcode") || (*variant == "xcode" && *xcode == "") {
		return errors.New("export requires complete image identity and a new layout path")
	}
	path, err := vmPath(*vm)
	if err != nil {
		return err
	}
	if err := validateVM(ctx, path); err != nil {
		return err
	}
	if err := os.Mkdir(*layout, 0700); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(*layout)
		}
	}()
	registry, err := newRegistry(*layout, true)
	if err != nil {
		return err
	}
	defer registry.close()
	labels := map[string]string{
		"org.opencontainers.image.revision": *revision,
		"org.opencontainers.image.source":   *source, "dev.macos-image.version": *osVersion,
		"dev.macos-image.build": *build, "dev.macos-image.variant": *variant,
	}
	if *xcode != "" {
		labels["dev.macos-image.xcode-version"] = *xcode
	}
	command := []string{"tart", "push", *vm, registry.reference() + ":image", "--insecure", "--concurrency", "2", "--chunk-size", "16"}
	for key, value := range labels {
		command = append(command, "--label", key+"="+value)
	}
	if err := run(ctx, 45*time.Minute, tartEnvironment(registry.host), command...); err != nil {
		return err
	}
	if err := registry.finish(); err != nil {
		return err
	}
	_, _, err = inspect(*layout)
	return err
}

func importImage(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("import", flag.ContinueOnError)
	layout := flags.String("layout", "", "Verified OCI layout directory")
	vm := flags.String("vm", "", "New local VM name")
	if err := flags.Parse(args); err != nil {
		return err
	}
	path, err := vmPath(*vm)
	if err != nil {
		return err
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		return errors.New("VM destination exists or cannot be checked")
	}
	if _, _, err := inspect(*layout); err != nil {
		return err
	}
	registry, err := newRegistry(*layout, false)
	if err != nil {
		return err
	}
	defer registry.close()
	if err := run(ctx, 45*time.Minute, tartEnvironment(registry.host), "tart", "clone", registry.reference()+":image", *vm, "--insecure", "--concurrency", "2"); err != nil {
		return err
	}
	return validateVM(ctx, path)
}
