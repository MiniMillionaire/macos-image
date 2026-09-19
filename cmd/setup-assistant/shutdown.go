package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func shutdownCredentials() (string, error) {
	for _, name := range []string{"GUEST_USERNAME", "GUEST_PASSWORD"} {
		if os.Getenv(name) == "" {
			return "", fmt.Errorf("%s is required for --shutdown", name)
		}
	}
	askpass, err := filepath.Abs("scripts/guest-ssh-askpass")
	if err != nil {
		return "", err
	}
	info, err := os.Stat(askpass)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return "", errors.New("guest SSH askpass script must be an executable file")
	}
	return askpass, nil
}

func requestGuestShutdown(ctx context.Context, vm, askpass string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	ipCtx, cancelIP := context.WithTimeout(ctx, 10*time.Second)
	output, err := exec.CommandContext(ipCtx, "tart", "ip", vm).Output()
	ipContextError := ipCtx.Err()
	cancelIP()
	if err != nil {
		if ipContextError != nil {
			err = ipContextError
		}
		return fmt.Errorf("could not find the guest address for shutdown: %w", err)
	}
	host := strings.TrimSpace(string(output))
	address := net.ParseIP(host)
	if address == nil || !address.IsPrivate() {
		return errors.New("guest shutdown requires a private VM address")
	}
	command := exec.CommandContext(ctx, "/usr/bin/ssh",
		"-F", "/dev/null", "-T",
		"-o", "UseKeychain=no", "-o", "AddKeysToAgent=no",
		"-o", "IdentityAgent=none", "-o", "IdentityFile=none", "-o", "IdentitiesOnly=yes",
		"-o", "PubkeyAuthentication=no", "-o", "HostbasedAuthentication=no",
		"-o", "GSSAPIAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
		"-o", "PreferredAuthentications=password", "-o", "PasswordAuthentication=yes",
		"-o", "NumberOfPasswordPrompts=1",
		"-o", "UserKnownHostsFile=/dev/null", "-o", "GlobalKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
		"-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
		"-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
		"-l", os.Getenv("GUEST_USERNAME"), host, "/bin/bash -se")
	command.Env = append(os.Environ(), "SSH_ASKPASS="+askpass, "SSH_ASKPASS_REQUIRE=force", "DISPLAY=:0")
	command.Stdin = strings.NewReader("sync\nsudo -n /usr/bin/true\nprintf 'MACOS_IMAGE_SHUTDOWN_REQUESTED\\n'\nexec sudo -n /sbin/shutdown -h now\n")
	command.WaitDelay = 5 * time.Second
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err = command.Output()
	if ctx.Err() != nil {
		return fmt.Errorf("guest shutdown request canceled: %w", ctx.Err())
	}
	var exitError *exec.ExitError
	acknowledged := strings.Contains(string(output), "MACOS_IMAGE_SHUTDOWN_REQUESTED\n")
	if err != nil && !(acknowledged && errors.As(err, &exitError) && exitError.ExitCode() == 255) {
		return fmt.Errorf("guest shutdown command failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	if !acknowledged {
		return errors.New("guest did not acknowledge the shutdown request")
	}
	return nil
}

func shutdownVM(ctx context.Context, vm string, process *vmProcess, askpass string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	select {
	case <-process.done:
		return errors.New("VM exited before the guest shutdown request")
	default:
	}
	if err := requestGuestShutdown(ctx, vm, askpass); err != nil {
		return err
	}
	waitCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	if err := process.wait(waitCtx); err != nil {
		return fmt.Errorf("guest did not shut down normally: %w", err)
	}
	fmt.Println("Guest shut down normally")
	return nil
}
