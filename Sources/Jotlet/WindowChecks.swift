import AppKit
import JotletCore

enum WindowCheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

/// Runs only in the test VM. A separate reference app supplies real focus and window ordering.
@MainActor
func runWindowChecks(_ delegate: AppDelegate) async throws {
    let shared = URL(fileURLWithPath: "/Volumes/My Shared Files")
    let output = shared.appendingPathComponent("output")
    var passed = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw WindowCheckFailure.failed(description) }
        passed += 1
        print("PASS window \(passed): \(description)")
        fflush(stdout)
    }
    func waitFor(_ description: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw WindowCheckFailure.failed("Timed out: \(description)")
    }
    func settle() async throws { try await Task.sleep(nanoseconds: 350_000_000) }
    func windowOrder() -> [Int] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
    }
    func capture(_ name: String) throws {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", output.appendingPathComponent(name + ".png").path]
        try capture.run(); capture.waitUntilExit()
        try check(capture.terminationStatus == 0, "screenshot saved: \(name)")
    }

    try await waitFor("app launch") { delegate.store != nil }
    try check(delegate.store.notes.isEmpty, "window checks use an empty isolated library")
    delegate.newNote(nil)
    guard let first = delegate.noteWindows.values.first, let noteWindow = first.window else {
        throw WindowCheckFailure.failed("New note window was not created")
    }
    try await waitFor("note focus") { noteWindow.isKeyWindow }
    try check(!delegate.store.note(first.noteID)!.isPinned && noteWindow.level == .normal,
              "new note is a normal independent window")
    first.editor.insertText("虚拟机窗口检查\n对着另一个窗口查看这张便签。", replacementRange: NSRange(location: 0, length: 0))
    try check(first.flush(), "note content saves before focus changes")
    let screen = NSScreen.main!.visibleFrame
    noteWindow.setFrame(NSRect(x: screen.maxX - 450, y: screen.minY + 110, width: 430, height: 410), display: true)
    delegate.libraryWindow.window?.orderOut(nil)

    let reference = Process()
    reference.executableURL = shared.appendingPathComponent("input/WindowReference.app/Contents/MacOS/WindowReference")
    try reference.run()
    defer {
        _ = delegate.flushAll()
        if reference.isRunning { reference.terminate(); reference.waitUntilExit() }
    }
    let referencePID = reference.processIdentifier
    try await waitFor("reference app launch") { NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID }
    try await settle()
    guard let referenceApp = NSRunningApplication(processIdentifier: referencePID) else {
        throw WindowCheckFailure.failed("Reference app is unavailable")
    }
    func referenceWindowID() -> Int? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == referencePID &&
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
            .flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
    }
    try await waitFor("reference window on screen") { referenceWindowID() != nil }
    guard let referenceID = referenceWindowID() else { throw WindowCheckFailure.failed("Reference window is not on screen") }
    func isAhead(_ front: Int, _ back: Int) -> Bool {
        let order = windowOrder()
        guard let a = order.firstIndex(of: front), let b = order.firstIndex(of: back) else { return false }
        return a < b
    }
    try check(noteWindow.isVisible && !noteWindow.isKeyWindow,
              "note remains visible when another app has focus")
    try check(isAhead(referenceID, noteWindow.windowNumber),
              "normal note stays behind the active overlapping reference window")
    try capture("window-normal-reference")

    NSApp.activate(ignoringOtherApps: true); first.present()
    try await waitFor("return to note") { noteWindow.isKeyWindow }
    first.togglePin(nil)
    let originalDock = delegate.hidesDockIcon
    let noteFrame = noteWindow.frame
    delegate.showSettings(nil)
    try await waitFor("settings focus") { delegate.settingsWindow?.window?.isKeyWindow == true }
    try check(delegate.libraryWindow.window?.isVisible == false && noteWindow.isVisible,
              "settings opens without the library and preserves the note")
    delegate.setDockIconHidden(true)
    try await settle()
    try check(NSApp.activationPolicy() == .accessory && UserDefaults.standard.bool(forKey: "JotletHidesDockIcon"),
              "hide-Dock setting uses accessory mode and persists")
    try check(noteWindow.isVisible && noteWindow.frame == noteFrame && noteWindow.level == .floating,
              "changing Dock visibility preserves note geometry and pin level")
    try check(delegate.settingsWindow?.window?.isVisible == true &&
              isAhead(delegate.settingsWindow!.window!.windowNumber, noteWindow.windowNumber),
              "settings stays above pinned notes and outside note-window cycling")
    try capture("window-settings-accessory")
    delegate.settingsWindow?.window?.performClose(nil)
    referenceApp.activate(options: [])
    try await waitFor("reference focus in accessory mode") { NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID }
    delegate.showLibrary(nil)
    try await waitFor("accessory library on screen") { windowOrder().contains(delegate.libraryWindow.window!.windowNumber) }
    try check(noteWindow.isVisible, "menu-bar mode can show the library while keeping independent notes")
    delegate.openNote(first.noteID)
    try await waitFor("accessory note focus") { noteWindow.isKeyWindow }
    try check(delegate.libraryWindow.window?.isVisible == false && first.editor.string.contains("虚拟机窗口检查"),
              "accessory mode opens an editable note and dismisses the library")
    delegate.setDockIconHidden(false)
    try check(NSApp.activationPolicy() == .regular && !UserDefaults.standard.bool(forKey: "JotletHidesDockIcon"),
              "Dock visibility can be restored without restarting")
    if originalDock { delegate.setDockIconHidden(true) }
    referenceApp.activate(options: [])
    try await waitFor("reference focus with pinned note") { NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID }
    try await settle()
    try check(noteWindow.isVisible && !noteWindow.isKeyWindow && noteWindow.level == .floating,
              "pinned note remains visible while the reference app owns focus")
    try check(isAhead(noteWindow.windowNumber, referenceID),
              "WindowServer places the pinned note above the overlapping reference window")
    try capture("window-pinned-reference")

    NSApp.activate(ignoringOtherApps: true); first.present()
    try await waitFor("unpin focus") { noteWindow.isKeyWindow }
    first.togglePin(nil)
    referenceApp.activate(options: [])
    try await waitFor("reference focus after unpin") { NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID }
    try await settle()
    try check(noteWindow.level == .normal && isAhead(referenceID, noteWindow.windowNumber),
              "unpin returns the note below the active reference window")

    NSApp.activate(ignoringOtherApps: true); first.present()
    try await waitFor("note focus restored") { noteWindow.isKeyWindow }
    try check(first.editor.string.contains("虚拟机窗口检查"), "returning to the note preserves its content")
    delegate.newNote(nil)
    let second = delegate.noteWindows.values.first { $0.noteID != first.noteID }!
    try await waitFor("second note focus") { second.window!.isKeyWindow }
    try check(noteWindow.isVisible && second.window!.isVisible, "two notes remain independent visible windows")
    delegate.toggleNotes(nil)
    try check(!noteWindow.isVisible && !second.window!.isVisible, "hide-notes action hides both note windows")
    delegate.toggleNotes(nil)
    try await settle()
    try check(noteWindow.isVisible && second.window!.isVisible, "restore-notes action restores both windows")

    first.present(); noteWindow.performClose(nil)
    try await settle()
    try check(!noteWindow.isVisible && delegate.store.note(first.noteID)?.isVisible == false,
              "closing a note hides it and records its closed state")
    try check(try delegate.store.content(first.noteID).string.contains("虚拟机窗口检查"),
              "closing the window preserves saved note content")
    delegate.openNote(first.noteID)
    try await waitFor("reopened note focus") { noteWindow.isKeyWindow }
    try check(noteWindow.isVisible && delegate.store.note(first.noteID)?.isVisible == true,
              "reopening the note restores the independent window")
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    try await settle()
    try check(delegate.libraryWindow.window?.isVisible == false && noteWindow.isKeyWindow,
              "reopen returns to the recent note without showing the library")
    try capture("window-reopen-fixed")

    referenceApp.activate(options: [])
    try await waitFor("reference before library") { NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID && !noteWindow.isKeyWindow && !NSApp.isActive }
    try await settle()
    delegate.showLibrary(nil)
    try await waitFor("floating library focus") { delegate.libraryWindow.window?.isKeyWindow == true }
    try await settle()
    print("Library state: visible=\(delegate.libraryWindow.window!.isVisible) key=\(delegate.libraryWindow.window!.isKeyWindow) appActive=\(NSApp.isActive) frame=\(delegate.libraryWindow.window!.frame)")
    try check(windowOrder().contains(delegate.libraryWindow.window!.windowNumber),
              "floating library is actually on screen over another active app")
    try check(delegate.libraryWindow.window is NSPanel && delegate.libraryWindow.window?.canBecomeMain == false,
              "library is a temporary panel outside the main-window cycle")
    try check(noteWindow.isVisible, "showing the library preserves the open note")
    try capture("window-floating-library")
    if ProcessInfo.processInfo.environment["JOTLET_MANUAL_WINDOWS"] == "1" {
        print("WAIT: click the reference window through the isolated VM console."); fflush(stdout)
        try await waitFor("outside click dismisses library", seconds: 120) { delegate.libraryWindow.window?.isVisible == false }
        try check(noteWindow.isVisible, "clicking outside dismisses only the list")
    } else {
        print("MANUAL: outside-click input is checked separately through the VM console.")
        delegate.libraryWindow.dismiss()
    }
    delegate.showLibrary(nil)
    try await waitFor("library lookup") { delegate.libraryWindow.window?.isVisible == true }
    delegate.openNote(first.noteID)
    try await waitFor("note chosen from library") { noteWindow.isKeyWindow }
    try check(delegate.libraryWindow.window?.isVisible == false, "choosing a note dismisses the floating list")

    let fullFrame = noteWindow.frame
    first.togglePin(nil); first.hideNote(nil)
    try await settle()
    try check(!noteWindow.isVisible && !windowOrder().contains(noteWindow.windowNumber) &&
              delegate.store.note(first.noteID)?.isVisible == false,
              "hide-note removes the whole window including its title bar")
    try check(second.window!.isVisible && delegate.store.note(first.noteID)?.frame?.rect == fullFrame &&
              delegate.store.note(first.noteID)?.isPinned == true,
              "hiding one note preserves its full frame, pinning and other open notes")
    referenceApp.activate(options: [])
    try await waitFor("reference before hidden-note restore") { NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID && !NSApp.isActive }
    try capture("window-note-hidden")
    delegate.toggleRecentNote(nil)
    try await waitFor("restore recent hidden note") { noteWindow.isKeyWindow }
    try await settle()
    try check(noteWindow.frame == fullFrame &&
              noteWindow.level == .floating && first.editor.string.contains("虚拟机窗口检查"),
              "recent-note action restores the hidden note with geometry, pinning and content")
    try check(delegate.libraryWindow.window?.isVisible == false, "restoring a hidden note avoids showing the list")
    delegate.toggleRecentNote(nil)
    try await waitFor("hide the active note with its shortcut action") { !noteWindow.isVisible }
    delegate.toggleRecentNote(nil)
    try await waitFor("immediate shortcut restore") { noteWindow.isKeyWindow }
    try check(second.window!.isVisible && noteWindow.isVisible,
              "repeating the note shortcut restores the just-hidden note instead of hiding another")
    var legacy = delegate.store.note(first.noteID)!
    legacy.isCollapsed = true
    let restored = try NoteWindowController(note: legacy, store: delegate.store, app: delegate)
    try check(restored.window!.frame.height == fullFrame.height && delegate.store.note(first.noteID)?.isCollapsed == false,
              "legacy title-bar notes reopen at their saved full size")
    first.togglePin(nil)
    delegate.setDockIconHidden(true)
    first.present()
    try check(delegate.cycleNoteWindows(), "accessory mode handles the same-app window shortcut")
    try await waitFor("cycle to the second note") { second.window!.isKeyWindow }
    try check(delegate.libraryWindow.window?.isVisible == false && noteWindow.isVisible,
              "cycling in accessory mode skips the library and keeps notes independent")
    try check(delegate.cycleNoteWindows(backwards: true), "accessory mode handles reverse window cycling")
    try await waitFor("cycle back to the first note") { noteWindow.isKeyWindow }
    delegate.setDockIconHidden(originalDock)
    referenceApp.activate(options: [])
    try await waitFor("reference before edge handle") { NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID }
    let edgeWasVisible = delegate.library.showsEdgeHandle
    if !edgeWasVisible { delegate.toggleEdgeHandle(nil) }
    try await settle()
    try check(delegate.edgeHandle.window?.isVisible == true && delegate.edgeHandle.window?.canBecomeKey == false &&
              NSWorkspace.shared.frontmostApplication?.processIdentifier == referencePID,
              "edge launcher appears without stealing the reference app's focus")
    try capture("window-edge-handle")
    if !edgeWasVisible { delegate.toggleEdgeHandle(nil) }
    print("Window checks completed: \(passed) passed.")
}
