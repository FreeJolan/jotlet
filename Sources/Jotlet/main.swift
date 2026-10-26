import AppKit
import SwiftUI

let windowChecks = ProcessInfo.processInfo.arguments.contains("--window-checks")
if windowChecks && (ProcessInfo.processInfo.environment["JOTLET_VM_TEST"] != "1" ||
                   !FileManager.default.fileExists(atPath: "/Volumes/My Shared Files/input/guest-test.sh")) {
    fputs("Window checks must run in the Tart test VM.\n", stderr); exit(2)
}
let app = NSApplication.shared
let fixture = windowChecks || ProcessInfo.processInfo.arguments.contains("--library-preview") || ProcessInfo.processInfo.arguments.contains("--smoke-test")
app.setActivationPolicy(!fixture && UserDefaults.standard.bool(forKey: "JotletHidesDockIcon") ? .accessory : .regular)
if ProcessInfo.processInfo.arguments.contains("--library-preview") {
    // Isolated visual fixture for active/inactive controls, without loading the user's notes.
    let model = LibraryModel()
    let controller = LibraryWindowController(model: model)
    let state: ControlActiveState = ProcessInfo.processInfo.arguments.contains("--inactive") ? .inactive : .key
    let dark = ProcessInfo.processInfo.arguments.contains("--dark")
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
    let quit = NSMenuItem(title: "退出预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = app; appMenu.addItem(quit); appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
    let preview = NSHostingView(rootView: LibraryView(model: model).environment(\.controlActiveState, state))
    preview.wantsLayer = true; preview.layer?.cornerRadius = 12; preview.layer?.masksToBounds = true
    controller.window?.contentView = preview
    controller.window?.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}
if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
    do { try runSmokeTests(); exit(0) }
    catch { fputs("Native integration check failed: \(error)\n", stderr); exit(1) }
}
let delegate = AppDelegate()
app.delegate = delegate
if windowChecks {
    Task { @MainActor in
        do { try await runWindowChecks(delegate); exit(0) }
        catch { fputs("Window check failed: \(error)\n", stderr); exit(1) }
    }
}
app.run()
