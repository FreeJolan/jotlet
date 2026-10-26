import AppKit
import UniformTypeIdentifiers
import JotletCore

final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let noteID: UUID
    let store: NoteStore
    weak var app: AppDelegate?
    let editor = RichTextView(frame: .zero)
    let status = label("已保存", size: 11)
    private var pinButton: NSButton!
    private var saveTask: DispatchWorkItem?
    private var frameTask: DispatchWorkItem?
    private var hasUnsavedChanges = false
    private var previewWindow: NSWindow?

    init(note: Note, store: NoteStore, app: AppDelegate) throws {
        noteID = note.id; self.store = store; self.app = app
        let content = try store.content(note.id)
        let rect = safeFrame(note.frame?.rect, size: NSSize(width: 440, height: 440))
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.setFrame(rect, display: false)
        window.title = note.title; window.minSize = NSSize(width: 380, height: 280)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.hidesOnDeactivate = false
        // Explicitly managed floating windows belong to one Space and appear in Mission Control.
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
        window.level = note.isPinned ? .floating : .normal
        super.init(window: window)
        window.delegate = self
        configure(content: content, pinned: note.isPinned)
        // 0.2.0 stored the full frame separately from its collapsed title bar.
        // Reopen these notes at their saved full size in the new hide/restore flow.
        if note.isCollapsed == true { try store.update(note.id) { $0.isCollapsed = false } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(content: NSAttributedString, pinned: Bool) {
        guard let window else { return }
        let root = NSView(); window.contentView = root
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let hideButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "收起便签")!, target: self, action: #selector(hideNote))
        hideButton.isBordered = false; hideButton.refusesFirstResponder = true
        hideButton.frame = NSRect(x: 0, y: 0, width: 30, height: 28)
        hideButton.toolTip = "完全收起这张便签 ⌥⌘K"; hideButton.setAccessibilityLabel("收起便签")
        accessory.view = hideButton; window.addTitlebarAccessoryViewController(accessory)
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        pinButton = symbolButton("pin.fill", title: "置顶这张便签", target: self, action: #selector(togglePin))
        pinButton.setButtonType(.pushOnPushOff); pinButton.state = pinned ? .on : .off
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        toolbar.addArrangedSubview(pinButton)
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
        toolbar.addArrangedSubview(divider)
        let headings = NSPopUpButton(); headings.addItems(withTitles: ["正文", "标题", "小标题"])
        headings.target = editor; headings.action = #selector(RichTextView.heading(_:)); headings.refusesFirstResponder = true
        headings.font = .systemFont(ofSize: 12); headings.widthAnchor.constraint(equalToConstant: 70).isActive = true
        headings.setAccessibilityLabel("段落格式"); toolbar.addArrangedSubview(headings)
        let formats: [(String, String, Selector)] = [
            ("bold", "加粗 ⌘B", #selector(RichTextView.toggleBoldface(_:))),
            ("italic", "斜体 ⌘I", #selector(RichTextView.toggleItalics(_:))),
            ("underline", "下划线 ⌘U", #selector(RichTextView.toggleUnderline(_:))),
            ("list.bullet", "项目列表", #selector(RichTextView.bulletList(_:))),
            ("checklist", "勾选清单 ⇧⌘L，也可输入 - [] 后按空格", #selector(RichTextView.checklist(_:)))
        ]
        for (symbol, title, action) in formats { toolbar.addArrangedSubview(symbolButton(symbol, title: title, target: editor, action: action)) }
        toolbar.addArrangedSubview(symbolButton("photo", title: "插入图片", target: self, action: #selector(insertImage)))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(symbolButton("rectangle.grid.1x2", title: "所有便签 ⌘0", target: app, action: #selector(AppDelegate.showLibrary)))
        root.addSubview(toolbar)
        let separator = NSBox(); separator.boxType = .separator; separator.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(separator)

        editor.isRichText = true; editor.importsGraphics = true; editor.allowsUndo = true
        editor.isAutomaticLinkDetectionEnabled = true; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = true
        editor.isContinuousSpellCheckingEnabled = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: window.frame.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 14, height: 18)
        editor.backgroundColor = .textBackgroundColor; editor.drawsBackground = true
        editor.textStorage?.setAttributedString(content)
        if content.length > 0 { editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: content.length)) }
        editor.typingAttributes = RichTextView.bodyAttributes
        editor.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        editor.detectLinks()
        editor.refreshPresentation()
        editor.delegate = self; editor.setAccessibilityLabel("便签内容")
        editor.previewImage = { [weak self] image in self?.showImage(image) }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor; scroll.documentView = editor
        scroll.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(scroll)
        status.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(status)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor), separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8), status.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(editor)
        app?.perform { try store.update(noteID) { $0.isVisible = true } }
    }
    @objc func hideNote(_ sender: Any?) { window?.performClose(sender) }
    @objc func togglePin(_ sender: Any?) {
        let pinned = !(store.note(noteID)?.isPinned ?? false)
        do {
            try store.update(noteID) { $0.isPinned = pinned }
            window?.level = pinned ? .floating : .normal
            pinButton.state = pinned ? .on : .off; pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
            pinButton.toolTip = pinned ? "取消置顶" : "置顶这张便签"
        } catch { app?.showError(error) }
    }

    func textDidChange(_ notification: Notification) {
        app?.noteDidEdit(noteID)
        hasUnsavedChanges = true; status.stringValue = "保存中…"; status.textColor = .secondaryLabelColor
        editor.needsDisplay = true
        saveTask?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flush() }
        saveTask = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    @discardableResult func flush() -> Bool {
        saveTask?.cancel(); frameTask?.cancel()
        do {
            if hasUnsavedChanges {
                try store.save(noteID, content: editor.attributedString())
                hasUnsavedChanges = false
            }
            if let frame = window?.frame, store.note(noteID)?.frame != WindowFrame(frame) {
                try store.update(noteID) { $0.frame = WindowFrame(frame) }
            }
            status.stringValue = "已保存"; status.textColor = .tertiaryLabelColor
            window?.title = store.note(noteID)?.title ?? "新便签"
            return true
        } catch {
            status.stringValue = "保存失败，内容仍在窗口中。请重试或导出。"
            status.textColor = .systemRed; app?.lastSaveError = error
            return false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard flush() else { app?.showError(app?.lastSaveError ?? JotletError.corruptLibrary); return false }
        do {
            try store.update(noteID) { $0.isVisible = false }
            sender.orderOut(nil); app?.noteDidHide(noteID)
        }
        catch { app?.showError(error) }
        return false
    }
    func windowDidResignKey(_ notification: Notification) { _ = flush() }
    func windowDidBecomeKey(_ notification: Notification) { app?.noteDidBecomeKey(noteID) }
    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    private func scheduleFrameSave() {
        frameTask?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flush() }; frameTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    @objc func insertImage(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.prompt = "插入"; panel.message = "图片会保存在便签中"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.editor.insertImages(panel.urls.compactMap { NSImage(contentsOf: $0) }); window.makeFirstResponder(self.editor)
        }
    }
    private func showImage(_ image: NSImage) {
        let window = NSWindow(contentRect: safeFrame(nil, size: NSSize(width: 760, height: 600)), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "图片预览"; window.isReleasedWhenClosed = false; window.level = .floating
        window.collectionBehavior = [.managed]; window.tabbingMode = .disallowed
        let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter; window.contentView = view
        previewWindow = window; window.makeKeyAndOrderFront(nil)
    }
}
