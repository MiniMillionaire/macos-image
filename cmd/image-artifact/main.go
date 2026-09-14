package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := execute(ctx, os.Args[1:]); err != nil {
		var child *exec.ExitError
		if errors.As(err, &child) && child.ExitCode() > 0 {
			os.Exit(child.ExitCode())
		}
		fmt.Fprintln(os.Stderr, err)
		if errors.Is(err, context.DeadlineExceeded) {
			os.Exit(124)
		}
		os.Exit(1)
	}
}

func execute(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: image-artifact <fetch|run|export|import|inspect> [options]")
	}
	switch args[0] {
	case "run":
		flags := flag.NewFlagSet("run", flag.ContinueOnError)
		seconds := flags.Int("timeout", 600, "Maximum command duration in seconds")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		if *seconds <= 0 || flags.NArg() == 0 {
			return errors.New("run requires a positive timeout and a command")
		}
		return run(ctx, time.Duration(*seconds)*time.Second, os.Environ(), flags.Args()...)
	case "fetch":
		return fetch(ctx, args[1:])
	case "export":
		return exportImage(ctx, args[1:])
	case "import":
		return importImage(ctx, args[1:])
	case "inspect":
		flags := flag.NewFlagSet("inspect", flag.ContinueOnError)
		layout := flags.String("layout", "", "OCI layout directory")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		_, info, err := inspect(*layout)
		if err != nil {
			return err
		}
		return writeJSON(os.Stdout, info)
	default:
		return fmt.Errorf("unknown command: %s", args[0])
	}
}

func run(ctx context.Context, timeout time.Duration, env []string, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return err
	}
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Env = env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		reaped := false
		select {
		case <-done:
			reaped = true
		case <-time.After(5 * time.Second):
		}
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if !reaped {
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				return fmt.Errorf("command did not exit after SIGKILL: %w", ctx.Err())
			}
		}
		return fmt.Errorf("command stopped: %w", ctx.Err())
	}
}
