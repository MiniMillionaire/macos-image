import AppKit

final class WitnessView: NSView {
    let journal: URL
    let nonce: String
    var text = ""
    var clicks = 0
    var windowReady = false
    var observedEvents: [[String: Any]] = []
    let target = NSRect(x: 80, y: 80, width: 160, height: 120)
    override var acceptsFirstResponder: Bool { true }

    init(journal: URL, nonce: String) {
        self.journal = journal
        self.nonce = nonce
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
    }

    required init?(coder: NSCoder) { fatalError("Unsupported") }

    func observe(_ event: NSEvent) {
        guard observedEvents.count < 128 else { return }
        let point = convert(event.locationInWindow, from: nil)
        observedEvents.append([
            "type": event.type.rawValue, "window": event.windowNumber,
            "point": [point.x, point.y], "timestamp": event.timestamp,
            "application_active": NSApp.isActive, "window_is_key": window?.isKeyWindow ?? false
        ])
        persist()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        target.fill()
        NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1).setFill()
        NSRect(x: 300, y: 80, width: 160, height: 120).fill()
        let value = "Offline VNC acceptance\n" + nonce + "\n" + text
        value.draw(at: NSPoint(x: 30, y: 240), withAttributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        ])
    }

    func persist() {
        guard let window, let screen = window.screen else { return }
        let rectangle = window.convertToScreen(convert(target, to: nil))
        let screenFrame = screen.frame
        let record: [String: Any] = [
            "schema_version": 1, "nonce": nonce, "ready": windowReady,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "screen": [screenFrame.origin.x, screenFrame.origin.y, screenFrame.width, screenFrame.height],
            "target": [rectangle.origin.x - screenFrame.origin.x,
                       screenFrame.maxY - rectangle.maxY, rectangle.width, rectangle.height],
            "target_rgb": [255, 0, 255], "clicks": clicks, "text": text,
            "window_is_key": window.isKeyWindow, "application_active": NSApp.isActive,
            "observed_events": observedEvents
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: journal, options: .atomic)
        } catch {
            fputs("Witness persistence failed: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if target.contains(convert(event.locationInWindow, from: nil)) {
            clicks += 1
            window?.makeFirstResponder(self)
            persist()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard clicks > 0, let characters = event.characters else { return }
        text += characters
        needsDisplay = true
        persist()
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var focusControl: NSWindow?
    var monitor: Any?
    let journal: URL
    let nonce: String

    init(journal: URL, nonce: String) {
        self.journal = journal
        self.nonce = nonce
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 160, width: 600, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Offline input witness"
        window.isReleasedWhenClosed = false
        let view = WitnessView(journal: journal, nonce: nonce)
        window.contentView = view
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp]) { event in
            view.observe(event)
            return event
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in view.persist() }
        let focusControl = NSWindow(contentRect: NSRect(x: 900, y: 100, width: 200, height: 100),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        focusControl.title = "Focus control fixture"
        focusControl.isReleasedWhenClosed = false
        self.focusControl = focusControl
        focusControl.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            view.windowReady = true
            view.persist()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.count == 2 && ["--pointer", "--input-state"].contains(CommandLine.arguments[1]) {
    guard let point = CGEvent(source: nil)?.location else { fatalError("Cannot sample guest pointer") }
    let value: Any = CommandLine.arguments[1] == "--pointer" ? [point.x, point.y] : [
        "pointer": [point.x, point.y],
        "left_button": CGEventSource.buttonState(.combinedSessionState, button: .left)
    ]
    let data = try JSONSerialization.data(withJSONObject: value)
    FileHandle.standardOutput.write(data)
    exit(0)
}
guard CommandLine.arguments.count == 3 else { fatalError("Expected journal and nonce") }
let path = CommandLine.arguments[1]
let nonce = CommandLine.arguments[2]
guard path.hasPrefix("/private/tmp/offline-vnc-witness-"), path.hasSuffix(".json"),
      !path.contains(".."), nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
      !FileManager.default.fileExists(atPath: path) else { fatalError("Invalid verification scope") }
let application = NSApplication.shared
let delegate = Delegate(journal: URL(fileURLWithPath: path), nonce: nonce)
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
