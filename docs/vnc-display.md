# VNC display synchronization

The macOS 26 investigation on the macOS 27.0 (26A5425a) host found that Tart
2.36.0 initially advertises a 1280 by 720 VNC display. The configured guest
display is 1024 by 768 logical points with a 2048 by 1536 framebuffer. Before a
display-size update, the server scales pointer coordinates using the temporary
VNC dimensions.

## Controlled observations

The experiments used new clones of a mapped macOS 26.6.2 VM with Remote Login
enabled. SSH independently read the console user and `NSEvent.mouseLocation`.
No screenshots were taken during these experiments. Coordinates below use the
guest's top-left origin and are rounded to the nearest logical point.

| Connection state | Sent VNC coordinate | Observed guest coordinate |
| --- | --- | --- |
| No framebuffer request | (400, 300) | (320, 320) |
| No framebuffer request | (1600, 1000) | (1024, 768), clamped |
| Zero-area request after boot | (400, 300) | (200, 150) |
| Production controller after size confirmation | (400, 300) | (200, 150) |
| Production controller after size confirmation | (1600, 1000) | (800, 500) |

The incorrect position follows the temporary dimensions exactly:
`400 / 1280 * 1024 = 320` and `300 / 720 * 768 = 320`.
Keyboard input without any framebuffer request successfully logged in as
`admin`; SSH confirmed the console user. This rules out a general input failure.

Development screenshots had completed the missing size synchronization before
pointer mapping. A clean production connection did not. An early zero-area
request without checking the resulting dimensions was insufficient: the second
clean build still failed. Its timing relative to guest display initialization
must not determine whether pointer coordinates are valid.

## Production behavior

After the configured boot wait, each connection sends a zero-area framebuffer
update request. It must confirm the expected dimensions within 30 seconds before
any setup input is sent. A different size or a missing response fails the phase.

Tart sends a `DesktopSize` rectangle with encoding `-223`, followed by a raw
framebuffer payload even for this zero-area request. The production reader uses
only the dimensions and streams the raw payload directly to `io.Discard`. It
does not decode colors, construct an image, save a screenshot, or inspect pixels.
Discarding the payload preserves protocol framing without affecting any action
or decision. Tests check metadata parsing, truncated messages, and exact payload
discarding without consuming the next protocol message.

The protocol fields are defined in
[RFC 6143, sections 7.5.3 and 7.8.2](https://www.rfc-editor.org/rfc/rfc6143.html).
