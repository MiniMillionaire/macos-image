package main

import (
	"bytes"
	"testing"

	"github.com/mitchellh/go-vnc"
)

func TestDisplayUpdate(t *testing.T) {
	data := []byte{0, 0, 1, 0, 0, 0, 0, 8, 0, 6, 0, 255, 255, 255, 33}
	message, err := (&displayUpdate{}).Read(nil, bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	update := message.(*displayUpdate)
	if update.Width != 2048 || update.Height != 1536 {
		t.Fatalf("unexpected dimensions: %#v", update)
	}
	for length := range len(data) {
		if _, err := (&displayUpdate{}).Read(nil, bytes.NewReader(data[:length])); err == nil {
			t.Fatalf("accepted truncated update with %d bytes", length)
		}
	}
}

func TestDisplayUpdateDiscardsOnlyThePixelPayload(t *testing.T) {
	header := []byte{0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0}
	pixels := []byte{1, 2, 3, 4}
	client := &vnc.ClientConn{PixelFormat: vnc.PixelFormat{BPP: 32}}
	data := append(append(header, pixels...), 42)
	reader := bytes.NewReader(data)
	message, err := (&displayUpdate{}).Read(client, reader)
	if err != nil {
		t.Fatal(err)
	}
	if update := message.(*displayUpdate); update.Width != 0 || update.Height != 0 {
		t.Fatal("treated pixels as display metadata")
	}
	if next, err := reader.ReadByte(); err != nil || next != 42 || reader.Len() != 0 {
		t.Fatal("did not preserve the next protocol message")
	}
	if _, err := (&displayUpdate{}).Read(client, bytes.NewReader(data[:len(header)+3])); err == nil {
		t.Fatal("accepted a truncated pixel payload")
	}
}

func TestEmptyDisplayUpdate(t *testing.T) {
	message, err := (&displayUpdate{}).Read(nil, bytes.NewReader([]byte{0, 0, 0}))
	if err != nil {
		t.Fatal(err)
	}
	if update := message.(*displayUpdate); update.Width != 0 || update.Height != 0 {
		t.Fatalf("unexpected empty update: %#v", update)
	}
}
