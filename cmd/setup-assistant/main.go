package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
	"unicode"

	"github.com/mitchellh/go-vnc"
)

type point struct {
	X uint16 `json:"x"`
	Y uint16 `json:"y"`
}

type scrollAction struct {
	X     uint16 `json:"x"`
	Y     uint16 `json:"y"`
	Steps int    `json:"steps"`
}

type action struct {
	Wait   string        `json:"wait,omitempty"`
	Key    string        `json:"key,omitempty"`
	Text   string        `json:"text,omitempty"`
	Click  *point        `json:"click,omitempty"`
	Scroll *scrollAction `json:"scroll,omitempty"`
	Chord  []string      `json:"chord,omitempty"`
	Repeat int           `json:"repeat,omitempty"`
}

type sequence struct {
	Width   uint16   `json:"width"`
	Height  uint16   `json:"height"`
	Actions []action `json:"actions"`
}

type endpoint struct {
	Host     string
	Password string
}

type desktopSizeEncoding struct{}

func (*desktopSizeEncoding) Read(client *vnc.ClientConn, rectangle *vnc.Rectangle, _ io.Reader) (vnc.Encoding, error) {
	client.FrameBufferWidth = rectangle.Width
	client.FrameBufferHeight = rectangle.Height
	return &desktopSizeEncoding{}, nil
}

func (*desktopSizeEncoding) Type() int32 {
	return -223
}

func main() {
	var vm string
	var endpointURL string
	var sequencePath string
	var initialWait string
	var screenshotPath string
	var keyInterval string

	flag.StringVar(&vm, "vm", "", "Tart VM name")
	flag.StringVar(&endpointURL, "endpoint", "", "existing Tart VNC endpoint")
	flag.StringVar(&sequencePath, "sequence", "", "setup sequence JSON path")
	flag.StringVar(&initialWait, "initial-wait", "90s", "delay before the first action")
	flag.StringVar(&screenshotPath, "screenshot", "", "write the final framebuffer to this path")
	flag.StringVar(&keyInterval, "key-interval", "100ms", "delay between key events")
	flag.Parse()

	if err := run(vm, endpointURL, sequencePath, initialWait, screenshotPath, keyInterval); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(vm, endpointURL, sequencePath, initialWait, screenshotPath, keyInterval string) error {
	if sequencePath == "" {
		return errors.New("--sequence is required")
	}
	if (vm == "") == (endpointURL == "") {
		return errors.New("exactly one of --vm and --endpoint is required")
	}

	setup, err := loadSequence(sequencePath)
	if err != nil {
		return err
	}
	wait, err := time.ParseDuration(initialWait)
	if err != nil {
		return fmt.Errorf("invalid initial wait: %w", err)
	}
	interval, err := time.ParseDuration(keyInterval)
	if err != nil {
		return fmt.Errorf("invalid key interval: %w", err)
	}
	if wait < 0 || interval < 0 {
		return errors.New("wait durations cannot be negative")
	}
	if err := setup.validate(); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()

	var server endpoint
	if endpointURL != "" {
		var ok bool
		server, ok, err = parseEndpoint(endpointURL)
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("invalid VNC endpoint")
		}
	} else {
		fmt.Printf("Starting %s\n", vm)
		command := exec.CommandContext(ctx, "tart", "run", vm, "--no-graphics", "--vnc-experimental", "--no-audio")
		command.Env = append(os.Environ(), "CI=true")
		stdout, err := command.StdoutPipe()
		if err != nil {
			return err
		}
		command.Stderr = os.Stderr
		if err := command.Start(); err != nil {
			return err
		}
		defer stopVM(vm, command)

		server, err = waitForEndpoint(ctx, stdout)
		if err != nil {
			return err
		}
	}
	connection, err := (&net.Dialer{Timeout: 30 * time.Second}).DialContext(ctx, "tcp", server.Host)
	if err != nil {
		return err
	}
	defer connection.Close()
	closeOnCancel := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer closeOnCancel()
	if err := connection.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		return err
	}

	messages := make(chan vnc.ServerMessage, 8)
	client, err := vnc.Client(connection, &vnc.ClientConfig{
		Auth:            []vnc.ClientAuth{&vnc.PasswordAuth{Password: server.Password}},
		ServerMessageCh: messages,
	})
	if err != nil {
		return err
	}
	defer client.Close()
	deadline, _ := ctx.Deadline()
	if err := connection.SetDeadline(deadline); err != nil {
		return err
	}
	if err := client.SetEncodings([]vnc.Encoding{&vnc.RawEncoding{}, &desktopSizeEncoding{}}); err != nil {
		return err
	}
	// Initialize Virtualization.framework input without requesting pixels.
	if err := client.FramebufferUpdateRequest(false, 0, 0, 0, 0); err != nil {
		return err
	}

	if wait > 0 {
		fmt.Printf("Waiting %s for Setup Assistant\n", wait)
		if err := waitFor(ctx, wait); err != nil {
			return err
		}
	}
	for index, current := range setup.Actions {
		if current.Wait != "" {
			duration, _ := time.ParseDuration(current.Wait)
			if duration >= 30*time.Second {
				fmt.Printf("Waiting %s at action %d of %d\n", duration, index+1, len(setup.Actions))
			}
		}
		repeat := max(current.Repeat, 1)
		for range repeat {
			if err := perform(ctx, client, messages, setup.Width, setup.Height, current, interval); err != nil {
				return fmt.Errorf("action %d: %w", index+1, err)
			}
		}
	}
	if screenshotPath != "" {
		if err := capture(client, messages, setup.Width, setup.Height, screenshotPath); err != nil {
			return err
		}
	}
	fmt.Println("Setup Assistant sequence completed")

	return nil
}

func (setup sequence) validate() error {
	for index, current := range setup.Actions {
		set := 0
		if current.Wait != "" {
			set++
		}
		if current.Key != "" {
			set++
		}
		if current.Text != "" {
			set++
		}
		if current.Click != nil {
			set++
			if current.Click.X >= setup.Width || current.Click.Y >= setup.Height {
				return fmt.Errorf("action %d: click is outside the configured display", index+1)
			}
		}
		if current.Scroll != nil {
			set++
			if current.Scroll.X >= setup.Width || current.Scroll.Y >= setup.Height {
				return fmt.Errorf("action %d: scroll is outside the configured display", index+1)
			}
			if current.Scroll.Steps == 0 || current.Scroll.Steps < -100 || current.Scroll.Steps > 100 {
				return fmt.Errorf("action %d: scroll steps must be between -100 and 100", index+1)
			}
		}
		if len(current.Chord) != 0 {
			set++
		}
		if set != 1 {
			return fmt.Errorf("action %d: exactly one operation is required", index+1)
		}
		if current.Repeat < 0 || current.Repeat > 1 && current.Key == "" && len(current.Chord) == 0 {
			return fmt.Errorf("action %d: repeat requires a key or chord", index+1)
		}
		if current.Wait != "" {
			duration, err := time.ParseDuration(current.Wait)
			if err != nil {
				return fmt.Errorf("action %d: %w", index+1, err)
			}
			if duration < 0 {
				return fmt.Errorf("action %d: wait duration cannot be negative", index+1)
			}
		}
	}
	return nil
}

func loadSequence(path string) (sequence, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return sequence{}, err
	}
	var result sequence
	if err := json.Unmarshal(contents, &result); err != nil {
		return sequence{}, err
	}
	if result.Width == 0 || result.Height == 0 {
		return sequence{}, errors.New("sequence width and height are required")
	}
	return result, nil
}

func waitForEndpoint(ctx context.Context, stdout io.Reader) (endpoint, error) {
	found := make(chan endpoint, 1)
	failed := make(chan error, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		sent := false
		for scanner.Scan() {
			if sent {
				continue
			}
			result, ok, err := parseEndpoint(scanner.Text())
			if err != nil {
				failed <- err
				return
			}
			if !ok {
				continue
			}
			found <- result
			sent = true
		}
		if !sent {
			failed <- scanner.Err()
		}
	}()

	select {
	case result := <-found:
		return result, nil
	case err := <-failed:
		if err == nil {
			err = errors.New("Tart exited before publishing a VNC endpoint")
		}
		return endpoint{}, err
	case <-time.After(30 * time.Second):
		return endpoint{}, errors.New("timed out waiting for Tart VNC endpoint")
	case <-ctx.Done():
		return endpoint{}, ctx.Err()
	}
}

func parseEndpoint(line string) (endpoint, bool, error) {
	line = strings.TrimSpace(line)
	start := strings.Index(line, "vnc://")
	if start == -1 {
		return endpoint{}, false, nil
	}
	parsed, err := url.Parse(line[start:])
	if err != nil {
		return endpoint{}, false, err
	}
	password, ok := parsed.User.Password()
	if !ok {
		return endpoint{}, false, errors.New("Tart VNC URL did not contain a password")
	}
	return endpoint{Host: parsed.Host, Password: password}, true, nil
}

func perform(ctx context.Context, client *vnc.ClientConn, messages <-chan vnc.ServerMessage, width, height uint16, current action, interval time.Duration) error {
	switch {
	case current.Wait != "":
		duration, err := time.ParseDuration(current.Wait)
		if err != nil {
			return err
		}
		return waitFor(ctx, duration)
	case current.Key != "":
		return tap(ctx, client, current.Key, interval)
	case current.Text != "":
		text, err := expandText(current.Text)
		if err != nil {
			return err
		}
		for _, character := range text {
			if err := tapRune(ctx, client, character, interval); err != nil {
				return err
			}
		}
		return nil
	case current.Click != nil:
		return click(ctx, client, *current.Click, interval)
	case current.Scroll != nil:
		return scroll(ctx, client, *current.Scroll, interval)
	default:
		return chord(ctx, client, current.Chord, interval)
	}
}

func expandText(value string) (string, error) {
	var missing string
	expanded := os.Expand(value, func(name string) string {
		switch name {
		case "GUEST_USERNAME", "GUEST_PASSWORD":
			value, ok := os.LookupEnv(name)
			if !ok || value == "" {
				missing = name
			}
			return value
		default:
			missing = name
			return ""
		}
	})
	if missing != "" {
		return "", fmt.Errorf("missing or unsupported text variable %q", missing)
	}
	return expanded, nil
}

func waitFor(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func tap(ctx context.Context, client *vnc.ClientConn, name string, interval time.Duration) error {
	key, err := keysym(name)
	if err != nil {
		return err
	}
	return tapKeysym(ctx, client, key, interval)
}

func tapKeysym(ctx context.Context, client *vnc.ClientConn, key uint32, interval time.Duration) error {
	if err := client.KeyEvent(key, true); err != nil {
		return err
	}
	if err := waitFor(ctx, interval); err != nil {
		return err
	}
	if err := client.KeyEvent(key, false); err != nil {
		return err
	}
	return waitFor(ctx, interval)
}

func tapRune(ctx context.Context, client *vnc.ClientConn, character rune, interval time.Duration) error {
	if !needsShift(character) {
		return tapKeysym(ctx, client, uint32(character), interval)
	}
	const shift = 0xffe1
	if err := client.KeyEvent(shift, true); err != nil {
		return err
	}
	pressed := true
	defer func() {
		if pressed {
			_ = client.KeyEvent(shift, false)
		}
	}()
	if err := waitFor(ctx, interval); err != nil {
		return err
	}
	if err := tapKeysym(ctx, client, uint32(character), interval); err != nil {
		return err
	}
	if err := client.KeyEvent(shift, false); err != nil {
		return err
	}
	pressed = false
	return waitFor(ctx, interval)
}

func needsShift(character rune) bool {
	return unicode.IsUpper(character) || strings.ContainsRune("~!@#$%^&*()_+{}|:\"<>?", character)
}

func chord(ctx context.Context, client *vnc.ClientConn, names []string, interval time.Duration) error {
	keys := make([]uint32, len(names))
	for index, name := range names {
		key, err := keysym(name)
		if err != nil {
			return err
		}
		keys[index] = key
		if err := client.KeyEvent(key, true); err != nil {
			return err
		}
		if err := waitFor(ctx, interval); err != nil {
			return err
		}
	}
	for index := len(keys) - 1; index >= 0; index-- {
		if err := client.KeyEvent(keys[index], false); err != nil {
			return err
		}
		if err := waitFor(ctx, interval); err != nil {
			return err
		}
	}
	return nil
}

func click(ctx context.Context, client *vnc.ClientConn, location point, interval time.Duration) error {
	if err := client.PointerEvent(0, location.X, location.Y); err != nil {
		return err
	}
	if err := waitFor(ctx, interval); err != nil {
		return err
	}
	if err := client.PointerEvent(vnc.ButtonLeft, location.X, location.Y); err != nil {
		return err
	}
	if err := waitFor(ctx, interval); err != nil {
		return err
	}
	return client.PointerEvent(0, location.X, location.Y)
}

func scroll(ctx context.Context, client *vnc.ClientConn, action scrollAction, interval time.Duration) error {
	button := vnc.Button5
	steps := action.Steps
	if steps < 0 {
		button = vnc.Button4
		steps = -steps
	}
	if err := client.PointerEvent(0, action.X, action.Y); err != nil {
		return err
	}
	for range steps {
		if err := client.PointerEvent(button, action.X, action.Y); err != nil {
			return err
		}
		if err := waitFor(ctx, interval); err != nil {
			return err
		}
		if err := client.PointerEvent(0, action.X, action.Y); err != nil {
			return err
		}
	}
	return nil
}

func keysym(name string) (uint32, error) {
	keys := map[string]uint32{
		"command": 0xffe9,
		"control": 0xffe3,
		"down":    0xff54,
		"enter":   0xff0d,
		"escape":  0xff1b,
		"f5":      0xffc2,
		"home":    0xff50,
		"option":  0xffe7,
		"shift":   0xffe1,
		"space":   0x0020,
		"tab":     0xff09,
		"up":      0xff52,
	}
	key, ok := keys[strings.ToLower(name)]
	if !ok {
		if len([]rune(name)) == 1 {
			return uint32([]rune(name)[0]), nil
		}
		return 0, fmt.Errorf("unknown key %q", name)
	}
	return key, nil
}

func capture(client *vnc.ClientConn, messages <-chan vnc.ServerMessage, width, height uint16, path string) error {
	frame := image.NewRGBA(image.Rect(0, 0, int(width), int(height)))
	if err := client.FramebufferUpdateRequest(false, 0, 0, client.FrameBufferWidth, client.FrameBufferHeight); err != nil {
		return err
	}

	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case message, ok := <-messages:
			if !ok {
				return errors.New("VNC connection closed before framebuffer capture")
			}
			update, ok := message.(*vnc.FramebufferUpdateMessage)
			if !ok {
				continue
			}
			hasPixels := false
			for _, rectangle := range update.Rectangles {
				raw, ok := rectangle.Enc.(*vnc.RawEncoding)
				if !ok {
					continue
				}
				hasPixels = true
				requiredWidth := int(rectangle.X + rectangle.Width)
				requiredHeight := int(rectangle.Y + rectangle.Height)
				if requiredWidth > frame.Bounds().Dx() || requiredHeight > frame.Bounds().Dy() {
					resized := image.NewRGBA(image.Rect(0, 0, max(requiredWidth, frame.Bounds().Dx()), max(requiredHeight, frame.Bounds().Dy())))
					draw.Draw(resized, frame.Bounds(), frame, image.Point{}, draw.Src)
					frame = resized
				}
				for index, pixel := range raw.Colors {
					x := index % int(rectangle.Width)
					y := index / int(rectangle.Width)
					frame.Set(int(rectangle.X)+x, int(rectangle.Y)+y, color.RGBA{uint8(pixel.R), uint8(pixel.G), uint8(pixel.B), 255})
				}
			}
			if !hasPixels {
				if err := client.FramebufferUpdateRequest(false, 0, 0, client.FrameBufferWidth, client.FrameBufferHeight); err != nil {
					return err
				}
				continue
			}
			if client.FrameBufferWidth != width || client.FrameBufferHeight != height {
				return fmt.Errorf("unexpected framebuffer size %dx%d", client.FrameBufferWidth, client.FrameBufferHeight)
			}
			file, err := os.Create(path)
			if err != nil {
				return err
			}
			err = png.Encode(file, frame)
			closeErr := file.Close()
			if err != nil {
				return err
			}
			return closeErr
		case <-deadline.C:
			return errors.New("timed out waiting for framebuffer")
		}
	}
}

func stopVM(vm string, command *exec.Cmd) {
	if command.Process == nil || command.ProcessState != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	stop := exec.CommandContext(ctx, "tart", "stop", vm, "--timeout", "30")
	stop.Stdout = os.Stdout
	stop.Stderr = os.Stderr
	_ = stop.Run()
	cancel()
	_ = command.Process.Signal(os.Interrupt)
	done := make(chan struct{})
	go func() {
		_ = command.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		_ = command.Process.Kill()
		<-done
	}
}
