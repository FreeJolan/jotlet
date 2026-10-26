import AppKit

final class SettingsWindowController: NSWindowController {
    private weak var app: AppDelegate?
    private let hideDock = NSButton(checkboxWithTitle: "隐藏 Dock 图标", target: nil, action: nil)
    private let showEdge = NSButton(checkboxWithTitle: "显示贴边入口", target: nil, action: nil)

    init(app: AppDelegate) {
        self.app = app
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 275),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jotlet 设置"; window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed; window.isExcludedFromWindowsMenu = true
        window.isFloatingPanel = true; window.level = .floating; window.hidesOnDeactivate = true
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        super.init(window: window)
        hideDock.target = self; hideDock.action = #selector(changeDock)
        showEdge.target = self; showEdge.action = #selector(changeEdge)
        let dockHint = NSTextField(wrappingLabelWithString: "开启后，⌘Tab 不再列出 Jotlet。可从菜单栏或 ⌥⌘0 打开便签列表。")
        let edgeHint = NSTextField(wrappingLabelWithString: "点击入口展开列表，拖动调整位置。鼠标经过不会弹出。")
        let shortcuts = NSTextField(wrappingLabelWithString: "⌥⌘N 新建便签    ⌥⌘J 隐藏 / 恢复全部\n⌥⌘K 收起当前便签 / 回到最近便签\n进入便签后，⌘` / ⇧⌘` 切换已打开的便签")
        for hint in [dockHint, edgeHint, shortcuts] { hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor }
        let content = NSStackView(views: [hideDock, dockHint, showEdge, edgeHint, shortcuts])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 9
        content.setCustomSpacing(23, after: dockHint); content.setCustomSpacing(22, after: edgeHint)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            dockHint.widthAnchor.constraint(equalTo: content.widthAnchor),
            edgeHint.widthAnchor.constraint(equalTo: content.widthAnchor),
            shortcuts.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        refresh()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func refresh() {
        hideDock.state = app?.hidesDockIcon == true ? .on : .off
        showEdge.state = app?.library.showsEdgeHandle == true ? .on : .off
    }
    @objc private func changeDock(_ sender: NSButton) { app?.setDockIconHidden(sender.state == .on) }
    @objc private func changeEdge(_ sender: NSButton) {
        if app?.library.showsEdgeHandle != (sender.state == .on) { app?.toggleEdgeHandle(nil) }
    }
}
