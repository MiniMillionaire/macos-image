package main

import (
	"context"
	"testing"
	"time"
)

func TestSequenceValidate(t *testing.T) {
	valid := sequence{
		Width:  1280,
		Height: 720,
		Actions: []action{
			{Wait: "1s"},
			{Key: "enter", Repeat: 2},
			{Text: "admin"},
			{Click: &point{X: 1279, Y: 719}},
			{Scroll: &scrollAction{X: 640, Y: 360, Steps: 10}},
			{Chord: []string{"command", "space"}},
		},
	}
	if err := valid.validate(); err != nil {
		t.Fatal(err)
	}

	tests := []sequence{
		{Width: 1280, Height: 720, Actions: []action{{}}},
		{Width: 1280, Height: 720, Actions: []action{{Wait: "1s", Key: "enter"}}},
		{Width: 1280, Height: 720, Actions: []action{{Wait: "1s", Repeat: 2}}},
		{Width: 1280, Height: 720, Actions: []action{{Key: "tab", Repeat: -1}}},
		{Width: 1280, Height: 720, Actions: []action{{Wait: "-1s"}}},
		{Width: 1280, Height: 720, Actions: []action{{Click: &point{X: 1280, Y: 0}}}},
		{Width: 1280, Height: 720, Actions: []action{{Scroll: &scrollAction{X: 1280, Y: 0, Steps: 1}}}},
		{Width: 1280, Height: 720, Actions: []action{{Scroll: &scrollAction{X: 0, Y: 0, Steps: 0}}}},
	}
	for _, setup := range tests {
		if err := setup.validate(); err == nil {
			t.Fatal("expected validation error")
		}
	}
}

func TestParseEndpoint(t *testing.T) {
	server, ok, err := parseEndpoint("VNC server is running at vnc://:secret@127.0.0.1:5900")
	if err != nil {
		t.Fatal(err)
	}
	if !ok || server.Host != "127.0.0.1:5900" || server.Password != "secret" {
		t.Fatalf("unexpected endpoint: %#v", server)
	}

	if _, ok, err := parseEndpoint("starting virtual machine"); err != nil || ok {
		t.Fatalf("unexpected result: ok=%v err=%v", ok, err)
	}
	if _, _, err := parseEndpoint("vnc://127.0.0.1:5900"); err == nil {
		t.Fatal("expected missing password error")
	}
}

func TestMacModifierKeys(t *testing.T) {
	command, err := keysym("command")
	if err != nil {
		t.Fatal(err)
	}
	option, err := keysym("option")
	if err != nil {
		t.Fatal(err)
	}
	if command != 0xffe9 || option != 0xffe7 {
		t.Fatalf("unexpected modifiers: command=%x option=%x", command, option)
	}
}

func TestExpandText(t *testing.T) {
	t.Setenv("GUEST_USERNAME", "admin")
	t.Setenv("GUEST_PASSWORD", "secret")

	value, err := expandText("${GUEST_USERNAME}:${GUEST_PASSWORD}")
	if err != nil {
		t.Fatal(err)
	}
	if value != "admin:secret" {
		t.Fatalf("unexpected value: %q", value)
	}
	if _, err := expandText("${UNKNOWN}"); err == nil {
		t.Fatal("expected unknown variable error")
	}
	t.Setenv("GUEST_PASSWORD", "")
	if _, err := expandText("${GUEST_PASSWORD}"); err == nil {
		t.Fatal("expected empty variable error")
	}
}

func TestSequoiaSequence(t *testing.T) {
	t.Setenv("GUEST_USERNAME", "admin")
	t.Setenv("GUEST_PASSWORD", "admin")
	paths := []string{
		"../../data/setup-assistant-sequoia-15.json",
		"../../data/setup-assistant-sequoia-15-resume.json",
		"../../data/setup-assistant-sequoia-15-final.json",
	}
	for _, path := range paths {
		setup, err := loadSequence(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := setup.validate(); err != nil {
			t.Fatal(err)
		}
		for _, current := range setup.Actions {
			if current.Text == "" {
				continue
			}
			if _, err := expandText(current.Text); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestWaitForCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	started := time.Now()
	if err := waitFor(ctx, time.Minute); err == nil {
		t.Fatal("expected cancellation error")
	}
	if time.Since(started) > time.Second {
		t.Fatal("cancellation was not immediate")
	}
}

func TestNeedsShift(t *testing.T) {
	for _, character := range "AZ!:_" {
		if !needsShift(character) {
			t.Fatalf("expected %q to need shift", character)
		}
	}
	for _, character := range "az1-.'" {
		if needsShift(character) {
			t.Fatalf("expected %q not to need shift", character)
		}
	}
}
