import AppKit
import SwiftUI
import JotletCore

final class LibraryModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var query = ""
    @Published var showingTrash = false
    @Published var showsEdgeHandle = false
    weak var app: AppDelegate?
    var filtered: [Note] {
        notes.filter { $0.isDeleted == showingTrash && (query.isEmpty || $0.preview.localizedStandardContains(query)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("便签").font(.system(size: 21, weight: .semibold))
                Spacer()
                if model.showingTrash && model.notes.contains(where: \.isDeleted) {
                    Button("清空废纸篓") { model.app?.emptyTrash(nil) }.foregroundStyle(.red)
                }
                Menu {
                    Button("设置…") { model.app?.showSettings(nil) }
                    Divider()
                    Button("导出完整备份…") { model.app?.exportBackup(nil) }
                    Button("从备份恢复…") { model.app?.importBackup(nil) }
                    Divider()
                    Button("打开自动备份文件夹") { model.app?.showBackupFolder(nil) }
                    Button("使用说明") { model.app?.showHelp(nil) }
                    Button("显示 / 隐藏已打开的便签") { model.app?.toggleNotes(nil) }
                    Divider()
                    Button(model.showsEdgeHandle ? "隐藏贴边入口" : "显示贴边入口") { model.app?.toggleEdgeHandle(nil) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).fixedSize().help("备份与窗口操作").accessibilityLabel("备份与窗口操作")
                Button { model.app?.newNote(nil) } label: { Label("新便签", systemImage: "plus") }
                    .buttonStyle(.bordered).foregroundStyle(.primary)
                    .keyboardShortcut("n", modifiers: .command).accessibilityLabel("新便签")
                Button { model.app?.libraryWindow.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("收起列表 Esc").accessibilityLabel("收起列表")
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            HStack(spacing: 14) {
                Picker("便签范围", selection: $model.showingTrash) {
                    Text("所有便签").tag(false)
                    Text("废纸篓").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 184)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    LibrarySearchField(model: model).frame(height: 22)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("清除搜索")
                    }
                }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if model.filtered.isEmpty {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: model.showingTrash ? "trash" : "note.text")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? (model.showingTrash ? "废纸篓是空的" : "先记下一个念头")
                         : "没有找到相关便签").font(.system(size: 17, weight: .medium))
                    if model.query.isEmpty && !model.showingTrash {
                        Text("写几句话，或贴一张截图。需要时把它置顶。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("新建便签") { model.app?.newNote(nil) }.buttonStyle(.bordered)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filtered) { note in
                            HStack(spacing: 12) {
                                Button { if !note.isDeleted { model.app?.openNote(note.id) } } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 7) {
                                            Text(note.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                            if note.isPinned && !note.isDeleted { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                                            Spacer()
                                        }
                                        Text(note.preview.isEmpty ? "空白便签" : note.preview.components(separatedBy: .newlines).dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
                                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                        Text(updatedLabel(note.modifiedAt)).font(.system(size: 11)).foregroundStyle(.tertiary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(note.isDeleted).accessibilityLabel("打开便签：\(note.title)")
                                if note.isDeleted {
                                    Button("恢复") { model.app?.restoreNote(note.id) }.buttonStyle(.bordered)
                                } else {
                                    Menu {
                                        Button("打开便签") { model.app?.openNote(note.id) }
                                        Button("导出为 HTML…") { model.app?.exportNote(note.id) }
                                        Divider()
                                        Button("移到废纸篓", role: .destructive) { model.app?.trashNote(note.id) }
                                    } label: { Image(systemName: "ellipsis").padding(6) }
                                    .menuStyle(.borderlessButton).fixedSize().help("便签操作").accessibilityLabel("便签操作：\(note.title)")
                                }
                            }.padding(.horizontal, 24).padding(.vertical, 16)
                            Divider().padding(.horizontal, 24)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(model.filtered.count) 张便签").monospacedDigit()
                Spacer()
                Text("Esc 收起列表").foregroundStyle(.secondary)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(minWidth: 420, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func updatedLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date()) + "更新"
    }
}

private struct LibrarySearchField: NSViewRepresentable {
    @ObservedObject var model: LibraryModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.placeholderString = "搜索正文"
        field.setAccessibilityLabel("搜索正文"); field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }
    func updateNSView(_ view: NSTextField, context: Context) {
        if view.currentEditor() == nil && view.stringValue != model.query { view.stringValue = model.query }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: LibraryModel
        weak var field: NSTextField?
        private var focusObserver: NSObjectProtocol?
        init(model: LibraryModel) {
            self.model = model; super.init()
            focusObserver = NotificationCenter.default.addObserver(forName: .init("JotletFocusSearch"), object: nil, queue: .main) { [weak self] _ in
                guard let field = self?.field else { return }
                field.window?.makeFirstResponder(field); field.currentEditor()?.selectAll(nil)
            }
        }
        deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
        func controlTextDidChange(_ notification: Notification) { if let field { model.query = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if let note = model.filtered.first, !note.isDeleted { model.app?.openNote(note.id) }
                return true
            }
            return false
        }
    }
}

final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    var isLauncherWindow: ((NSWindow) -> Bool)?
    private var menuTracking = false
    private var observers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    init(model: LibraryModel) {
        let window = LibraryPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 530),
                                  styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        window.title = "便签列表"; window.minSize = NSSize(width: 420, height: 400)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.isFloatingPanel = true; window.hidesOnDeactivate = false; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.isExcludedFromWindowsMenu = true; window.isMovableByWindowBackground = true
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        let host = NSHostingView(rootView: LibraryView(model: model))
        host.wantsLayer = true; host.layer?.cornerRadius = 12; host.layer?.masksToBounds = true
        window.contentView = host; window.center()
        super.init(window: window); window.delegate = self
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = true })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = false; self?.dismissAfterFocusChange()
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }
    func present(anchor: NSRect? = nil) {
        guard let window else { return }
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main!
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = window.frame.size
        var origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        if let anchor {
            if anchor.height >= 40 {
                origin.x = anchor.midX > bounds.midX ? anchor.minX - size.width - 8 : anchor.maxX + 8
                origin.y = anchor.maxY - size.height
            } else {
                origin = NSPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height - 6)
            }
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        window.setFrameOrigin(origin); window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window !== self.window, !self.menuTracking, NSApp.modalWindow == nil,
                   event.window.map({ self.isLauncherWindow?($0) != true }) ?? true { self.dismiss() }
                return event
            }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("JotletFocusSearch"), object: nil) }
    }
    func dismiss() {
        window?.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func windowDidResignKey(_ notification: Notification) { dismissAfterFocusChange() }
    private func dismissAfterFocusChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.isKeyWindow,
                  !self.menuTracking, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            self.dismiss()
        }
    }
}

private final class LibraryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
