import AppKit

/// Optional launcher. Its panel never becomes key, so clicking or moving it does not activate notes.
final class EdgeHandleController: NSWindowController {
    private let open: (NSRect) -> Void
    private var screenObserver: NSObjectProtocol?
    init(open: @escaping (NSRect) -> Void) {
        self.open = open
        let panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 22, height: 52),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true; panel.title = "Jotlet 贴边入口"
        super.init(window: panel)
        let handle = EdgeHandleView()
        handle.open = { [weak self] in guard let self, let frame = self.window?.frame else { return }; self.open(frame) }
        handle.snap = { [weak self] in self?.snapToEdge(save: true) }
        panel.contentView = handle
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }; self?.restorePosition()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    func present() { restorePosition(); window?.orderFrontRegardless() }
    func dismiss() { window?.orderOut(nil) }
    private func restorePosition() {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: "JotletEdgeDisplay")
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == saved }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let right = defaults.object(forKey: "JotletEdgeRight") == nil || defaults.bool(forKey: "JotletEdgeRight")
        let ratio = defaults.object(forKey: "JotletEdgeY") == nil ? 0.5 : defaults.double(forKey: "JotletEdgeY")
        window?.setFrameOrigin(NSPoint(x: right ? bounds.maxX - 22 : bounds.minX,
                                       y: bounds.minY + max(0, min(1, ratio)) * (bounds.height - 52)))
    }
    private func snapToEdge(save: Bool) {
        guard let window else { return }
        let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let right = point.x >= bounds.midX
        let y = max(bounds.minY, min(window.frame.minY, bounds.maxY - window.frame.height))
        window.setFrameOrigin(NSPoint(x: right ? bounds.maxX - window.frame.width : bounds.minX, y: y))
        if save {
            UserDefaults.standard.set(right, forKey: "JotletEdgeRight")
            UserDefaults.standard.set((y - bounds.minY) / max(1, bounds.height - window.frame.height), forKey: "JotletEdgeY")
            UserDefaults.standard.set((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue, forKey: "JotletEdgeDisplay")
        }
    }
}

private final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class EdgeHandleView: NSView {
    var open: (() -> Void)?
    var snap: (() -> Void)?
    private var startPoint = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragged = false
    private var hovering = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("展开便签列表")
        toolTip = "点击展开便签列表，拖动调整位置"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func accessibilityPerformPress() -> Bool { open?(); return true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        startPoint = NSEvent.mouseLocation; startOrigin = window?.frame.origin ?? .zero; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x - startPoint.x, point.y - startPoint.y) > 4 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: startOrigin.x + point.x - startPoint.x, y: startOrigin.y + point.y - startPoint.y)) }
    }
    override func mouseUp(with event: NSEvent) { if dragged { snap?() } else { open?() } }
    override func draw(_ dirtyRect: NSRect) {
        (hovering ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        if let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor)) {
            image.draw(in: NSRect(x: 4, y: bounds.midY - 8, width: 14, height: 16))
        }
    }
}
