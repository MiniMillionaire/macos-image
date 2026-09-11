package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"time"

	"github.com/mitchellh/go-vnc"
)

type displayUpdate struct {
	Width  uint16
	Height uint16
}

func (*displayUpdate) Type() uint8 { return 0 }

func (*displayUpdate) Read(client *vnc.ClientConn, reader io.Reader) (vnc.ServerMessage, error) {
	var header struct {
		Padding    uint8
		Rectangles uint16
	}
	if err := binary.Read(reader, binary.BigEndian, &header); err != nil {
		return nil, err
	}
	update := &displayUpdate{}
	for range header.Rectangles {
		var rectangle struct {
			X, Y, Width, Height uint16
			Encoding            int32
		}
		if err := binary.Read(reader, binary.BigEndian, &rectangle); err != nil {
			return nil, err
		}
		switch rectangle.Encoding {
		case -223:
			update.Width, update.Height = rectangle.Width, rectangle.Height
		case 0:
			bytesPerPixel := int64(client.PixelFormat.BPP / 8)
			if bytesPerPixel < 1 || bytesPerPixel > 4 || client.PixelFormat.BPP%8 != 0 {
				return nil, fmt.Errorf("unsupported VNC pixel size: %d", client.PixelFormat.BPP)
			}
			length := int64(rectangle.Width) * int64(rectangle.Height) * bytesPerPixel
			if _, err := io.CopyN(io.Discard, reader, length); err != nil {
				return nil, err
			}
		default:
			return nil, fmt.Errorf("unsupported VNC encoding: %d", rectangle.Encoding)
		}
	}
	return update, nil
}

func synchronizeDisplay(ctx context.Context, client *vnc.ClientConn, messages <-chan vnc.ServerMessage, width, height uint16) error {
	if err := client.FramebufferUpdateRequest(false, 0, 0, 0, 0); err != nil {
		return err
	}
	if client.FrameBufferWidth == width && client.FrameBufferHeight == height {
		fmt.Printf("VNC display confirmed: %dx%d\n", width, height)
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for {
		select {
		case message, ok := <-messages:
			if !ok {
				return fmt.Errorf("VNC connection closed before display dimensions were confirmed")
			}
			var actualWidth, actualHeight uint16
			switch update := message.(type) {
			case *displayUpdate:
				actualWidth, actualHeight = update.Width, update.Height
			case *vnc.FramebufferUpdateMessage:
				for _, rectangle := range update.Rectangles {
					if rectangle.Enc.Type() == -223 {
						actualWidth, actualHeight = rectangle.Width, rectangle.Height
					}
				}
			}
			if actualWidth == 0 && actualHeight == 0 {
				continue
			}
			if actualWidth != width || actualHeight != height {
				return fmt.Errorf("unexpected VNC display %dx%d; expected %dx%d", actualWidth, actualHeight, width, height)
			}
			client.FrameBufferWidth, client.FrameBufferHeight = actualWidth, actualHeight
			fmt.Printf("VNC display confirmed: %dx%d\n", width, height)
			return nil
		case <-ctx.Done():
			return fmt.Errorf("waiting for VNC display dimensions: %w", ctx.Err())
		}
	}
}
