import AppKit

final class PreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var target: CGRect? { didSet { needsDisplay = true } }
    var lost = false
    var onSelection: ((CGRect) -> Void)?
    private var start: CGPoint?, drag: CGRect?
    override var acceptsFirstResponder: Bool { true }
    private var videoRect: CGRect {
        TargetGeometry.imageRect(in: bounds, width: image?.width ?? 16, height: image?.height ?? 9)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill(); bounds.fill()
        guard let image = image, let context = NSGraphicsContext.current?.cgContext else {
            let text = "Your camera preview will appear here"
            let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 18)]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX-size.width/2, y: bounds.midY-size.height/2), withAttributes: attributes)
            return
        }
        context.draw(image, in: videoRect)
        let outline: CGRect?
        if let drag = drag { outline = drag }
        else if let target = target {
            let v = videoRect
            outline = CGRect(x: v.minX+target.minX*v.width, y: v.minY+target.minY*v.height, width: target.width*v.width, height: target.height*v.height)
        } else { outline = nil }
        if let rect = outline {
            let color: NSColor = lost ? .systemOrange : .systemMint
            color.withAlphaComponent(0.12).setFill(); rect.fill()
            color.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
            let label = lost ? "RESELECT MINI" : "FOCUS TARGET"
            let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
            label.draw(at: NSPoint(x: rect.minX+4, y: max(videoRect.minY, rect.maxY-19)), withAttributes: attributes)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard videoRect.contains(p) else { return }
        start = p; drag = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = start else { return }
        let raw = convert(event.locationInWindow, from: nil), v = videoRect
        let p = CGPoint(x: min(max(raw.x, v.minX), v.maxX), y: min(max(raw.y, v.minY), v.maxY))
        drag = CGRect(x: min(start.x,p.x), y: min(start.y,p.y), width: abs(start.x-p.x), height: abs(start.y-p.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; drag = nil; needsDisplay = true }
        guard let rect = drag, rect.width >= 18, rect.height >= 18 else { return }
        let v = videoRect
        onSelection?(CGRect(x: (rect.minX-v.minX)/v.width, y: (rect.minY-v.minY)/v.height, width: rect.width/v.width, height: rect.height/v.height))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = CameraEngine()
    private var window: NSWindow!
    private let preview = PreviewView()
    private let status = NSTextField(wrappingLabelWithString: "Connect your C930e to begin.")
    private let metrics = NSTextField(labelWithString: "FOCUS —     SHARPNESS —     TRACKING —")
    private let minimum = NSTextField(string: "0"), maximum = NSTextField(string: "255")
    private let track = NSButton(checkboxWithTitle: "Track miniature movement", target: nil, action: nil)
    private var start: NSButton!, hold: NSButton!, reacquire: NSButton!, restore: NSButton!, connect: NSButton!
    private var hadConnection = false
    private var lastSnapshot = CameraSnapshot()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 850), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "MiniFocus — Painting Companion"
        window.minSize = NSSize(width: 880, height: 740)
        window.delegate = self
        let root = NSView(); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        let title = NSTextField(labelWithString: "Keep the miniature in focus.")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Draw a tight box to focus on the mini and start following it. Keep this app open while OBS records.")
        subtitle.textColor = .secondaryLabelColor
        connect = button("Connect", #selector(connectCamera))
        start = button("Start following", #selector(startFollowing)); start.bezelColor = .systemTeal
        hold = button("Hold", #selector(holdFocus))
        reacquire = button("Reacquire", #selector(reacquireFocus))
        restore = button("Stop & restore", #selector(restoreFocus))
        start.toolTip = "Continuously check focus around the current lens position."
        reacquire.toolTip = "Search the full allowed range; the preview may blur briefly."
        restore.toolTip = "Stop focus changes and restore the settings present when you connected."
        let buttons = NSStackView(views: [connect, start, hold, reacquire, restore]); buttons.spacing = 10
        track.state = .on; track.target = self; track.action = #selector(toggleTracking)
        minimum.widthAnchor.constraint(equalToConstant: 60).isActive = true
        maximum.widthAnchor.constraint(equalToConstant: 60).isActive = true
        minimum.toolTip = "Lowest allowed lens position, in camera units. Applied on Start or Reacquire."
        maximum.toolTip = "Highest allowed lens position, in camera units. Applied on Start or Reacquire."
        let limits = NSStackView(views: [track, NSTextField(labelWithString: "Search limits:"), minimum, NSTextField(labelWithString: "to"), maximum])
        limits.spacing = 10
        metrics.font = .monospacedSystemFont(ofSize: 12, weight: .medium); metrics.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 14, weight: .medium); status.maximumNumberOfLines = 3
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        let help = NSTextField(wrappingLabelWithString: "Draw a box, then hold the mini inside it while focus is acquired. Tracking starts after the search.\nOBS: use the Logitech C930e as your Video Capture Device; leave native autofocus off. Hold pauses lens changes. Reacquire searches again. Search limits use lens units, not inches.")
        help.textColor = .secondaryLabelColor; help.font = .systemFont(ofSize: 12); help.maximumNumberOfLines = 4
        let stack = NSStackView(views: [title, subtitle, preview, buttons, limits, metrics, status, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        preview.onSelection = { [weak self] in self?.engine.select($0) }
        engine.onUpdate = { [weak self] in self?.update($0) }
        engine.diagnostic = CommandLine.arguments.contains("--diagnose")
        update(CameraSnapshot())
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if engine.diagnostic { engine.connect() }
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    private func buildMenu() {
        let menu = NSMenu(), application = NSMenuItem()
        menu.addItem(application)
        let app = NSMenu(); app.addItem(withTitle: "Quit MiniFocus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = app
        let editItem = NSMenuItem(); editItem.title = "Edit"; menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; NSApp.mainMenu = menu
    }
    private func update(_ value: CameraSnapshot) {
        lastSnapshot = value
        preview.image = value.image; preview.target = value.target; preview.lost = value.lost
        status.stringValue = value.message
        status.textColor = value.lost ? .systemOrange : .labelColor
        let mode = value.acquiring ? "ACQUIRING" : (value.active ? "FOLLOWING" : "IDLE / HOLD")
        metrics.stringValue = String(format: "FOCUS %d   ·   SHARPNESS %.1f   ·   TRACKING %.0f%%   ·   %@", value.focus, value.sharpness, Double(value.confidence)*100, mode)
        if value.connected && !hadConnection { minimum.stringValue = "\(value.minimum)"; maximum.stringValue = "\(value.maximum)" }
        hadConnection = value.connected
        connect.title = value.connected ? "Reconnect" : "Connect"; connect.isEnabled = true
        let canStart = value.connected && value.target != nil && !value.lost && value.image != nil
        start.isEnabled = canStart && !value.active; reacquire.isEnabled = canStart
        hold.isEnabled = value.active; restore.isEnabled = value.connected
    }
    @objc private func connectCamera() {
        connect.isEnabled = false
        if lastSnapshot.connected { engine.disconnect() }
        engine.connect()
    }
    private func run(wide: Bool) {
        guard let lo = Int(minimum.stringValue), let hi = Int(maximum.stringValue) else {
            status.stringValue = "Enter whole numbers for search limits."; return
        }
        engine.start(wide: wide, minimum: lo, maximum: hi)
    }
    @objc private func startFollowing() { run(wide: false) }
    @objc private func reacquireFocus() { run(wide: true) }
    @objc private func holdFocus() { engine.hold() }
    @objc private func restoreFocus() { engine.restore() }
    @objc private func toggleTracking() { engine.setTracking(track.state == .on) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return true }
    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }
}

@main
enum MiniFocusApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
