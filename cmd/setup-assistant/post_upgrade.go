package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"
)

func checkPostUpgrade(ctx context.Context, vm, askpass, checkPath, mode string) (string, error) {
	script, err := os.ReadFile("scripts/guest/post-upgrade-setup.sh")
	if err != nil {
		return "", err
	}
	if checkPath != "" {
		checks, err := os.ReadFile(checkPath)
		if err != nil {
			return "", err
		}
		script = append(append(checks, '\n'), script...)
	}
	var environment []string
	for _, name := range []string{"GUEST_USERNAME", "EXPECTED_VERSION", "EXPECTED_BUILD"} {
		value := os.Getenv(name)
		if value == "" {
			return "", fmt.Errorf("%s is required for post-upgrade setup", name)
		}
		environment = append(environment, name+"='"+strings.ReplaceAll(value, "'", "'\\''")+"'")
	}
	environment = append(environment, "POST_UPGRADE_MODE='"+mode+"'")
	return postUpgradeSSH(ctx, vm, askpass, strings.Join(environment, " ")+" /bin/bash -se", script)
}

func postUpgradeSSH(ctx context.Context, vm, askpass, remoteCommand string, script []byte) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	readyDeadline := time.Now().Add(3 * time.Minute)
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		ipCtx, cancelIP := context.WithTimeout(ctx, 10*time.Second)
		output, ipErr := exec.CommandContext(ipCtx, "tart", "ip", vm).Output()
		cancelIP()
		host := strings.TrimSpace(string(output))
		address := net.ParseIP(host)
		if ipErr == nil && address != nil && address.IsPrivate() {
			command := guestSSHCommand(ctx, host, askpass, remoteCommand)
			command.Stdin = bytes.NewReader(script)
			var stderr bytes.Buffer
			command.Stderr = &stderr
			output, err := command.Output()
			if ctx.Err() != nil {
				return "", ctx.Err()
			}
			if err == nil {
				return strings.TrimSpace(string(output)), nil
			}
			var exitError *exec.ExitError
			if !errors.As(err, &exitError) || exitError.ExitCode() != 255 || time.Now().After(readyDeadline) {
				return "", fmt.Errorf("post-upgrade guest check failed: %w: %s", err, strings.TrimSpace(stderr.String()))
			}
		}
		if time.Now().After(readyDeadline) {
			return "", errors.New("timed out connecting to the upgraded guest")
		}
		if err := waitFor(ctx, 5*time.Second); err != nil {
			return "", err
		}
	}
}
