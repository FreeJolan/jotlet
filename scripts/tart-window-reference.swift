import AppKit

guard ProcessInfo.processInfo.environment["JOTLET_VM_TEST"] == "1",
      FileManager.default.fileExists(atPath: "/Volumes/My Shared Files/input/guest-test.sh") else {
    fputs("The reference app only runs in the Tart test VM.\n", stderr)
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!.visibleFrame
let window = NSWindow(contentRect: NSRect(x: screen.minX + 30, y: screen.minY + 60,
                                        width: screen.width * 0.75, height: screen.height * 0.8),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Reference window in the test VM"
window.isReleasedWhenClosed = false
let content = NSTextField(wrappingLabelWithString: "Reference content\n\nThis separate app keeps focus while the note is pinned.\n\nThe left part of this window should stay visible.\nClosing the note must preserve its contents.")
content.font = .systemFont(ofSize: 22)
content.translatesAutoresizingMaskIntoConstraints = false
window.contentView!.addSubview(content)
NSLayoutConstraint.activate([
    content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
    content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
    content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 36)
])
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
