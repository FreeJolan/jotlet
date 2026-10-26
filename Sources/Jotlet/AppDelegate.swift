import AppKit
import Carbon
import UniformTypeIdentifiers
import JotletCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: NoteStore!
    let library = LibraryModel()
    var libraryWindow: LibraryWindowController!
    var noteWindows: [UUID: NoteWindowController] = [:]
    var lastSaveError: Error?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var backupTimer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hideHotKey: EventHotKeyRef?
    private var libraryHotKey: EventHotKeyRef?
    private var noteHotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var temporarilyHidden: Set<UUID> = []
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var diagnosticTimer: Timer?
    private var lastNoteID: UUID?
    private var lastHiddenNoteID: UUID?
    var edgeHandle: EdgeHandleController!
    private(set) var hidesDockIcon = UserDefaults.standard.bool(forKey: "JotletHidesDockIcon")
    private(set) var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try NoteStore(root: NoteStore.defaultRoot) }
        catch { showError(error); NSApp.terminate(nil); return }
        library.app = self; library.notes = store.notes
        libraryWindow = LibraryWindowController(model: library)
        library.showsEdgeHandle = UserDefaults.standard.bool(forKey: "JotletShowsEdgeHandle")
        edgeHandle = EdgeHandleController { [weak self] anchor in
            guard let self else { return }
            if self.libraryWindow.window?.isVisible == true { self.libraryWindow.dismiss() }
            else { self.libraryWindow.present(anchor: anchor) }
        }
        if library.showsEdgeHandle { edgeHandle.present() }
        store.onChange = { [weak self] in self?.library.notes = self?.store.notes ?? [] }
        configureMenus(); configureStatusItem(); registerHotKeys()
        libraryWindow.isLauncherWindow = { [weak self] window in
            window === self?.statusItem?.button?.window || window === self?.edgeHandle?.window
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for controller in self.noteWindows.values {
                if let window = controller.window { window.setFrame(safeFrame(window.frame, size: window.frame.size), display: true) }
            }
        }
        backupTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            guard let self, self.flushAll() else { return }
            do { try self.store.automaticBackup() } catch { self.lastSaveError = error; self.showError(error) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if modifiers == .command && event.keyCode == UInt16(kVK_ANSI_Comma) { self?.showSettings(nil); return nil }
            if self?.hidesDockIcon == true && event.keyCode == UInt16(kVK_ANSI_Grave),
               modifiers == .command || modifiers == [.command, .shift],
               self?.cycleNoteWindows(backwards: modifiers.contains(.shift)) == true { return nil }
            if modifiers == [.command, .option] {
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "n" || event.keyCode == UInt16(kVK_ANSI_N) { self?.newNote(nil); return nil }
                if key == "j" || event.keyCode == UInt16(kVK_ANSI_J) { self?.toggleNotes(nil); return nil }
                if key == "0" || event.keyCode == UInt16(kVK_ANSI_0) { self?.toggleLibrary(nil); return nil }
                if key == "k" || event.keyCode == UInt16(kVK_ANSI_K) { self?.toggleRecentNote(nil); return nil }
            }
            if event.keyCode == 53, NSApp.keyWindow === self?.libraryWindow.window,
               (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                self?.libraryWindow.dismiss(); return nil
            }
            if event.keyCode == 3 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               NSApp.keyWindow === self?.libraryWindow.window {
                NotificationCenter.default.post(name: .init("JotletFocusSearch"), object: nil); return nil
            }
            return event
        }
        if let recovery = store.recoveryMessage { showMessage("已恢复列表", text: recovery) }
        let visible = store.notes.filter { $0.isVisible && !$0.isDeleted }
        lastNoteID = UserDefaults.standard.string(forKey: "JotletLastNote").flatMap(UUID.init(uuidString:))
        lastHiddenNoteID = UserDefaults.standard.string(forKey: "JotletLastHiddenNote").flatMap(UUID.init(uuidString:))
        if visible.isEmpty { showLibrary(nil) }
        else {
            for note in visible { openNote(note.id, activate: false) }
            resumeNoteOrLibrary()
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            createFixture()
            if ProcessInfo.processInfo.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.writeDiagnostics() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { resumeNoteOrLibrary(); return true }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard libraryWindow != nil, NSApp.modalWindow == nil, libraryWindow.window?.isVisible != true else { return }
        if let key = NSApp.keyWindow, key.isVisible { return }
        if let id = mostRecentVisibleNote() {
            libraryWindow.dismiss(); noteWindows[id]?.present()
        } else { showLibrary(nil) }
    }
    func applicationDidResignActive(_ notification: Notification) { libraryWindow?.dismiss() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard flushAll() else { showError(lastSaveError ?? JotletError.corruptLibrary); return .terminateCancel }
        do { try store?.automaticBackup() } catch { showError(error); return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        backupTimer?.invalidate()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hideHotKey { UnregisterEventHotKey(hideHotKey) }
        if let libraryHotKey { UnregisterEventHotKey(libraryHotKey) }
        if let noteHotKey { UnregisterEventHotKey(noteHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func perform(_ work: () throws -> Void) { do { try work() } catch { showError(error) } }
    func showError(_ error: Error) {
        lastSaveError = error
        let alert = NSAlert(); alert.messageText = "暂时无法完成操作"
        alert.informativeText = error.localizedDescription; alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    func showMessage(_ title: String, text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @discardableResult func flushAll() -> Bool {
        var result = true
        for window in noteWindows.values { if !window.flush() { result = false } }
        return result
    }
    @objc func showLibrary(_ sender: Any?) {
        let anchor = (sender as? NSButton).flatMap { button in button.window?.convertToScreen(button.convert(button.bounds, to: nil)) }
        libraryWindow?.present(anchor: anchor)
    }
    @objc func toggleLibrary(_ sender: Any?) {
        if libraryWindow.window?.isVisible == true { libraryWindow.dismiss() }
        else { showLibrary(sender ?? statusItem?.button) }
    }
    func noteDidBecomeKey(_ id: UUID) {
        lastNoteID = id; UserDefaults.standard.set(id.uuidString, forKey: "JotletLastNote")
        if let event = NSApp.currentEvent, event.window === noteWindows[id]?.window,
           [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp].contains(event.type) { clearHiddenNote() }
    }
    func noteDidEdit(_ id: UUID) { if lastHiddenNoteID != id { clearHiddenNote() } }
    private func clearHiddenNote() {
        lastHiddenNoteID = nil; UserDefaults.standard.removeObject(forKey: "JotletLastHiddenNote")
    }
    func noteDidHide(_ id: UUID) {
        noteDidBecomeKey(id)
        lastHiddenNoteID = id; UserDefaults.standard.set(id.uuidString, forKey: "JotletLastHiddenNote")
    }
    private func mostRecentVisibleNote() -> UUID? {
        if let id = lastNoteID, noteWindows[id]?.window?.isVisible == true { return id }
        return store?.notes.first { !$0.isDeleted && noteWindows[$0.id]?.window?.isVisible == true }?.id
    }
    private func resumeNoteOrLibrary() {
        if let id = mostRecentVisibleNote() {
            lastNoteID = id; libraryWindow.dismiss()
            NSApp.activate(ignoringOtherApps: true); noteWindows[id]?.present()
        } else { showLibrary(nil) }
    }
    @objc func toggleEdgeHandle(_ sender: Any?) {
        library.showsEdgeHandle.toggle()
        UserDefaults.standard.set(library.showsEdgeHandle, forKey: "JotletShowsEdgeHandle")
        if library.showsEdgeHandle { edgeHandle.present() } else { edgeHandle.dismiss() }
        settingsWindow?.refresh()
    }
    @objc func showSettings(_ sender: Any?) {
        libraryWindow.dismiss()
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.present()
    }
    func setDockIconHidden(_ hidden: Bool) {
        let keyWindow = NSApp.keyWindow
        let wasActive = NSApp.isActive
        guard NSApp.setActivationPolicy(hidden ? .accessory : .regular) else { return }
        hidesDockIcon = hidden; UserDefaults.standard.set(hidden, forKey: "JotletHidesDockIcon")
        settingsWindow?.refresh()
        if wasActive, let keyWindow { keyWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func newNote(_ sender: Any?) {
        do {
            let note = try store.create(); openNote(note.id)
        } catch { showError(error) }
    }
    func openNote(_ id: UUID, activate: Bool = true) {
        guard let note = store.note(id), !note.isDeleted else { return }
        do {
            let controller: NoteWindowController
            if let existing = noteWindows[id] { controller = existing }
            else { controller = try NoteWindowController(note: note, store: store, app: self); noteWindows[id] = controller }
            if activate {
                lastNoteID = id; clearHiddenNote()
                libraryWindow?.dismiss(); controller.present(); NSApp.activate(ignoringOtherApps: true)
            }
            else { controller.window?.orderFront(nil) }
            temporarilyHidden.remove(id)
        } catch { showError(error) }
    }
    @objc func toggleNotes(_ sender: Any?) {
        if !temporarilyHidden.isEmpty {
            for id in temporarilyHidden { noteWindows[id]?.window?.orderFront(nil) }
            temporarilyHidden.removeAll()
        } else {
            for (id, controller) in noteWindows where controller.window?.isVisible == true {
                guard controller.flush() else { showError(lastSaveError ?? JotletError.corruptLibrary); return }
                temporarilyHidden.insert(id); controller.window?.orderOut(nil)
            }
        }
    }
    func trashNote(_ id: UUID) {
        if let controller = noteWindows[id], !controller.flush() { showError(lastSaveError ?? JotletError.corruptLibrary); return }
        perform {
            try store.trash(id); noteWindows[id]?.window?.orderOut(nil)
            noteWindows.removeValue(forKey: id); temporarilyHidden.remove(id)
        }
    }
    func restoreNote(_ id: UUID) {
        perform { try store.restore(id) }; library.showingTrash = false
        openNote(id)
    }
    @objc func emptyTrash(_ sender: Any?) {
        let count = store.notes.filter(\.isDeleted).count
        let alert = NSAlert(); alert.messageText = "清空废纸篓？"
        alert.informativeText = "将移除 \(count) 张便签。清空前会自动备份一次，你仍可从备份恢复。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空废纸篓")
        if alert.runModal() == .alertSecondButtonReturn { perform { try store.emptyTrash() } }
    }

    @objc func exportCurrentNote(_ sender: Any?) {
        if let id = noteWindows.first(where: { $0.value.window === NSApp.keyWindow })?.key { exportNote(id) }
    }
    func exportNote(_ id: UUID) {
        guard let note = store.note(id) else { return }
        // Export live content even when saving to the library failed.
        do {
            let content = try noteWindows[id]?.editor.attributedString() ?? store.content(id)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.html]
            let title = note.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            panel.nameFieldStringValue = title + ".html"; panel.title = "导出便签"; panel.prompt = "导出"
            if panel.runModal() == .OK, let url = panel.url {
                try HTMLExporter.document(title: note.title, content: content).write(to: url, atomically: true, encoding: .utf8)
            }
        } catch { showError(error) }
    }
    @objc func exportBackup(_ sender: Any?) {
        guard flushAll() else { showError(lastSaveError ?? JotletError.corruptLibrary); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "app.jotlet.backup", conformingTo: .data)]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Jotlet-\(formatter.string(from: Date())).jotletbackup"; panel.title = "导出完整备份"; panel.prompt = "导出"
        if panel.runModal() == .OK, let url = panel.url { perform { try store.exportBackup(to: url) } }
    }
    @objc func importBackup(_ sender: Any?) {
        guard flushAll() else { showError(lastSaveError ?? JotletError.corruptLibrary); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(exportedAs: "app.jotlet.backup", conformingTo: .data)]
        panel.allowsMultipleSelection = false; panel.title = "从备份恢复"; panel.message = "备份内容会作为新便签加入，现有便签会保留。"; panel.prompt = "恢复"
        if panel.runModal() == .OK, let url = panel.url {
            do { let count = try store.importBackup(from: url); library.showingTrash = false; showLibrary(nil); showMessage("恢复完成", text: "已加入 \(count) 张便签，原有内容保持完整。") }
            catch { showError(error) }
        }
    }
    @objc func showBackupFolder(_ sender: Any?) { NSWorkspace.shared.open(store.root.appendingPathComponent("Backups")) }
    @objc func retrySave(_ sender: Any?) { if !flushAll() { showError(lastSaveError ?? JotletError.corruptLibrary) } }
    @objc func about(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Jotlet", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.3", .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "8", .credits: NSAttributedString(string: "随手记，放在手边。\n本地保存，基础富文本与图片。")])
    }
    @objc func showHelp(_ sender: Any?) {
        showMessage("Jotlet 使用说明", text: "⌥⌘N：随时新建便签\n⌥⌘J：隐藏 / 恢复已打开的便签\n⌥⌘0：随时展开 / 收起便签列表\n⌘0：在便签内打开列表\n⌥⌘K：收起当前便签 / 回到最近便签\n\n点击菜单栏图标展开列表，Esc 或点击外部收起列表。\n设置中可隐藏 Dock 图标或开启贴边入口，拖动入口调整位置。\n点标题栏右侧箭头完全收起便签，从列表或 ⌥⌘K 找回。\n点图钉切换置顶，关闭窗口只会收起内容。\n在 Mission Control 中，把便签拖到需要的桌面。\n点清单前的方框可勾选，空清单行按回车退出清单。\n双击图片放大查看，右键图片可复制和调整大小。\n⌘点击链接打开网页。\n\n正文与图片自动保存在本机。每 15 分钟及退出时自动备份，保留最近 20 份。")
    }

    private func menuItem(_ title: String, _ action: Selector?, key: String = "", target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target; item.keyEquivalentModifierMask = modifiers; return item
    }
    private func configureMenus() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Jotlet")
        appMenu.addItem(menuItem("关于 Jotlet", #selector(about), target: self))
        appMenu.addItem(menuItem("设置…", #selector(showSettings), key: ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("隐藏 Jotlet", #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(menuItem("隐藏其他应用", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        appMenu.addItem(.separator()); appMenu.addItem(menuItem("退出 Jotlet", #selector(NSApplication.terminate(_:)), key: "q"))
        let file = NSMenu(title: "文件")
        file.addItem(menuItem("新便签", #selector(newNote), key: "n", target: self))
        file.addItem(menuItem("所有便签", #selector(showLibrary), key: "0", target: self))
        file.addItem(menuItem("显示 / 隐藏便签", #selector(toggleNotes), key: "h", target: self, modifiers: [.command, .shift]))
        file.addItem(.separator())
        file.addItem(menuItem("导出当前便签…", #selector(exportCurrentNote), key: "e", target: self, modifiers: [.command, .shift]))
        file.addItem(menuItem("导出完整备份…", #selector(exportBackup), target: self))
        file.addItem(menuItem("从备份恢复…", #selector(importBackup), target: self))
        file.addItem(menuItem("打开自动备份文件夹", #selector(showBackupFolder), target: self))
        file.addItem(menuItem("重试保存", #selector(retrySave), target: self))
        file.addItem(.separator()); file.addItem(menuItem("收起窗口", #selector(NSWindow.performClose(_:)), key: "w"))
        let edit = NSMenu(title: "编辑")
        edit.addItem(menuItem("撤销", Selector(("undo:")), key: "z"))
        edit.addItem(menuItem("重做", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(menuItem("剪切", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(menuItem("复制", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(menuItem("复制为 Markdown", #selector(RichTextView.copyMarkdown(_:)), key: "c", modifiers: [.command, .option]))
        edit.addItem(menuItem("粘贴", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(menuItem("粘贴 Markdown", #selector(RichTextView.pasteMarkdown(_:)), key: "v", modifiers: [.command, .option]))
        edit.addItem(menuItem("粘贴并匹配样式", #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift]))
        edit.addItem(menuItem("全选", #selector(NSText.selectAll(_:)), key: "a"))
        let format = NSMenu(title: "格式")
        format.addItem(menuItem("加粗", #selector(RichTextView.toggleBoldface(_:)), key: "b"))
        format.addItem(menuItem("斜体", #selector(RichTextView.toggleItalics(_:)), key: "i"))
        format.addItem(menuItem("下划线", #selector(RichTextView.toggleUnderline(_:)), key: "u"))
        format.addItem(.separator())
        format.addItem(menuItem("项目列表", #selector(RichTextView.bulletList(_:))))
        format.addItem(menuItem("编号列表", #selector(RichTextView.numberedList(_:))))
        format.addItem(menuItem("勾选清单", #selector(RichTextView.checklist(_:)), key: "l", modifiers: [.command, .shift]))
        format.addItem(menuItem("切换勾选状态", #selector(RichTextView.toggleCheck(_:)), key: "x", modifiers: [.command, .shift]))
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(menuItem("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(menuItem("全部前置", #selector(NSApplication.arrangeInFront(_:))))
        windowMenu.addItem(menuItem("收起 / 恢复最近便签", #selector(toggleRecentNote), key: "k", target: self, modifiers: [.command, .option]))
        for (title, submenu) in [("Jotlet", appMenu), ("文件", file), ("编辑", edit), ("格式", format), ("窗口", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = submenu; main.addItem(item)
        }
        NSApp.mainMenu = main; NSApp.windowsMenu = windowMenu
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(menuItem("Jotlet 使用说明", #selector(showHelp), target: self))
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: ""); helpItem.submenu = helpMenu
        main.addItem(helpItem); NSApp.helpMenu = helpMenu
    }
    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Jotlet")
        item.button?.toolTip = "Jotlet"
        item.button?.target = self; item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = NSMenu()
        menu.addItem(menuItem("新便签   ⌥⌘N", #selector(newNote), target: self))
        menu.addItem(menuItem("所有便签", #selector(showLibrary), target: self))
        menu.addItem(menuItem("收起 / 恢复最近便签   ⌥⌘K", #selector(toggleRecentNote), target: self))
        menu.addItem(menuItem("显示 / 隐藏便签   ⌥⌘J", #selector(toggleNotes), target: self))
        menu.addItem(menuItem("显示 / 隐藏贴边入口", #selector(toggleEdgeHandle), target: self))
        menu.addItem(menuItem("设置…", #selector(showSettings), target: self))
        menu.addItem(.separator()); menu.addItem(menuItem("退出 Jotlet", #selector(NSApplication.terminate(_:))))
        statusMenu = menu; statusItem = item
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           (event.type == .rightMouseUp || event.modifierFlags.contains(.control)), let statusMenu {
            libraryWindow.dismiss()
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else { toggleLibrary(sender) }
    }
    private func registerHotKeys() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if result == noErr {
                let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                switch id.id { case 1: app.newNote(nil); case 2: app.toggleNotes(nil); case 3: app.toggleLibrary(nil); default: app.toggleRecentNote(nil) }
            }
            return noErr
        }, 1, &event, context, &hotKeyHandler)
        let signature: OSType = 0x4A4F544C
        let first = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        let second = RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(cmdKey | optionKey), EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &hideHotKey)
        let third = RegisterEventHotKey(UInt32(kVK_ANSI_0), UInt32(cmdKey | optionKey), EventHotKeyID(signature: signature, id: 3), GetApplicationEventTarget(), 0, &libraryHotKey)
        let fourth = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), EventHotKeyID(signature: signature, id: 4), GetApplicationEventTarget(), 0, &noteHotKey)
        if first != noErr || second != noErr || third != noErr || fourth != noErr {
            DispatchQueue.main.async { [weak self] in self?.showMessage("快捷键被占用", text: "全局快捷键暂时无法注册。你仍可通过菜单栏新建和收起便签。") }
        }
    }
    @objc func toggleRecentNote(_ sender: Any?) {
        if let id = lastHiddenNoteID, store.note(id)?.isDeleted == false {
            openNote(id)
        } else if NSApp.isActive, let current = noteWindows.values.first(where: { $0.window === NSApp.keyWindow && $0.window?.isVisible == true }) {
            current.hideNote(sender)
        } else if let id = [lastHiddenNoteID, lastNoteID].compactMap({ $0 }).first(where: { store.note($0)?.isDeleted == false }) {
            openNote(id)
        } else { showLibrary(nil) }
    }
    @discardableResult func cycleNoteWindows(backwards: Bool = false) -> Bool {
        let candidates = store.notes.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }.compactMap { noteWindows[$0.id] }.filter {
            $0.window?.isVisible == true && $0.window?.isOnActiveSpace == true && $0.window?.isMiniaturized == false
        }
        guard let index = candidates.firstIndex(where: { $0.window === NSApp.keyWindow }) else { return false }
        let next = (index + (backwards ? -1 : 1) + candidates.count) % candidates.count
        clearHiddenNote(); candidates[next].present(); return true
    }
    private func createFixture() {
        perform {
            let text = NSMutableAttributedString(attributedString: try MarkdownFormatter.document("""
            # 今天随手记
            先记下来，稍后再整理。

            ## 待办
            - [] 把想法写成一个小步骤，再对着参考资料补充细节。这条比较长，可以看看换行是否对齐。
            - [] 试一下新的清单样式
              - [] 子任务也可以单独勾选
            - [x] 给自己留一点空白时间

            > 一次只做眼前的一小步。

            输入 `- []` 后按空格，就能新建待办。
            **重要的事**，也可以 *轻轻标注*，或 ~~划掉~~。
            """))
            if let path = ProcessInfo.processInfo.environment["JOTLET_FIXTURE_IMAGE"], let image = NSImage(contentsOfFile: path),
               let attachment = RichTextView.attachment(image, maxWidth: 360) {
                text.append(NSAttributedString(attachment: attachment))
            }
            let note = try store.create(content: text); openNote(note.id)
            noteWindows[note.id]?.window?.setFrame(NSRect(x: 250, y: 58, width: 520, height: 650), display: true)
        }
    }
    private func writeDiagnostics() {
        let values: [[String: Any]] = noteWindows.compactMap { id, controller in
            guard let window = controller.window else { return nil }
            return ["id": id.uuidString, "windowID": window.windowNumber, "level": window.level.rawValue,
                    "key": window.isKeyWindow,
                    "visible": window.isVisible, "onActiveSpace": window.isOnActiveSpace,
                    "managed": window.collectionBehavior.contains(.managed), "allSpaces": window.collectionBehavior.contains(.canJoinAllSpaces)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: store.root.appendingPathComponent("qa-state.json"), options: .atomic)
        }
    }
}
