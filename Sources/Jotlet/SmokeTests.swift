import AppKit
import JotletCore

enum SmokeFailure: Error { case assertion(String) }

/// Integration checks use the actual AppKit editor, pasteboard, undo manager and window controller.
/// The user's pasteboard is restored and the library lives in a temporary directory.
func runSmokeTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("JotletSmoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let board = NSPasteboard.general
    let previous = (board.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        board.clearContents()
        let items = previous.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
        }
        board.writeObjects(items)
    }
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw SmokeFailure.assertion(description) }
        print("PASS \(description)")
    }
    let store = try NoteStore(root: root)
    let delegate = AppDelegate(); delegate.store = store
    let note = try store.create()
    let controller = try NoteWindowController(note: note, store: store, app: delegate)
    let editor = controller.editor
    controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(editor)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    func clear() { editor.textStorage?.setAttributedString(NSAttributedString(string: "")); editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.typingAttributes = RichTextView.bodyAttributes; editor.undoManager?.removeAllActions() }
    func type(_ text: String) { for character in text { editor.insertText(String(character), replacementRange: editor.selectedRange()) } }
    board.clearContents(); board.setString("中文与 English\nemoji 📝\n最后一行", forType: .string)
    editor.paste(nil)
    try check(editor.string == "中文与 English\nemoji 📝\n最后一行", "plain-text paste preserves Unicode and line breaks")
    if let manager = editor.undoManager {
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }; manager.undo()
        try check(editor.string.isEmpty, "one undo removes one paste operation")
    }

    clear()
    board.clearContents(); board.setString("<p><b>加粗标题</b></p><ul><li>第一项</li><li>第二项</li></ul><p><a href='https://www.apple.com'>链接</a></p>", forType: .html)
    editor.paste(nil)
    try check(editor.string.contains("加粗标题") && editor.string.contains("第一项") && editor.string.contains("第二项"), "HTML paste preserves text and lists")
    let bold = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    try check(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, "HTML paste retains bold")
    let htmlRoundTrip = try NSAttributedString(data: NoteStore.encodeContent(editor.attributedString()), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    try check(htmlRoundTrip.string.contains("• 第一项") && htmlRoundTrip.string.contains("• 第二项"), "HTML list markers survive RTFD storage")
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length)); editor.copy(nil)
    try check(board.string(forType: .string)?.contains("加粗标题") == true && board.string(forType: .html)?.contains("<strong>") == true, "copy exposes both plain text and HTML")
    if let manager = editor.undoManager {
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }; manager.undo()
        try check(editor.string.isEmpty, "one undo removes a formatted paste including list markers")
    }

    clear()
    board.clearContents(); board.setString("<div data-lark-html-role='root'><h2>工作安排</h2><ol start='2'><li data-list='number'><h3><span style='font-size:14px'>编号标题</span></h3></li></ol><ol start='3'><li data-list='number'><h3>下一项</h3></li></ol></div>", forType: .html)
    editor.paste(nil)
    let numberedLines = editor.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    try check(numberedLines == ["工作安排", "2. 编号标题", "3. 下一项"], "Lark numbered headings paste with one number and correct start")
    let headingRange = (editor.string as NSString).range(of: "2. 编号标题")
    let headingFont = editor.textStorage?.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
    try check(headingFont.map { abs($0.pointSize - 19) < 0.1 && NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, "Lark heading and its number keep the heading font")
    let headingRoundTrip = try NSAttributedString(data: NoteStore.encodeContent(editor.attributedString()), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    let savedHeadingFont = headingRoundTrip.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
    try check(headingRoundTrip.string == editor.string && savedHeadingFont.map { abs($0.pointSize - 19) < 0.1 } == true, "numbered heading and style survive RTFD storage")
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length)); editor.copy(nil)
    let copiedLines = board.string(forType: .string)?.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    try check(copiedLines == numberedLines, "copying numbered headings keeps one number")
    if let manager = editor.undoManager {
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }; manager.undo()
        try check(editor.string.isEmpty, "one undo removes the numbered-heading paste")
        manager.redo()
        let restoredFont = editor.textStorage?.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        try check(editor.string == headingRoundTrip.string && restoredFont.map { abs($0.pointSize - 19) < 0.1 } == true, "redo restores the numbered heading and its font size")
    }
    editor.setSelectedRange(headingRange); editor.toggleItalics(nil)
    let editedHeadingFont = editor.textStorage?.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
    let editedHeadingSlant = editor.textStorage?.attribute(.obliqueness, at: headingRange.location, effectiveRange: nil) as? Double ?? 0
    try check(editedHeadingFont.map { abs($0.pointSize - 19) < 0.1 && (NSFontManager.shared.traits(of: $0).contains(.italicFontMask) || editedHeadingSlant != 0) } ?? false, "formatting a pasted heading preserves its font size")

    clear(); editor.insertText("手动标题", replacementRange: editor.selectedRange())
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    let paragraphMenu = NSPopUpButton(); paragraphMenu.addItems(withTitles: ["正文", "标题", "小标题"]); paragraphMenu.selectItem(at: 1)
    editor.heading(paragraphMenu)
    let manualHeadingFont = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    try check(editor.string == "手动标题" && manualHeadingFont.map { abs($0.pointSize - 25) < 0.1 } == true, "heading menu applies the selected heading size")

    clear(); type("# "); type("本周工作"); editor.insertNewline(nil); type("正文")
    let markdownHeadingFont = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let markdownBodyFont = editor.textStorage?.attribute(.font, at: (editor.string as NSString).range(of: "正文").location, effectiveRange: nil) as? NSFont
    try check(editor.string == "本周工作\n正文" && markdownHeadingFont?.pointSize == 25 && markdownBodyFont?.pointSize == 15, "typing a Markdown heading formats it and Return restores body text")

    clear(); type("## 小标题")
    try check(editor.string == "小标题" && (editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 19, "Markdown subheading prefix formats live")

    try runBackspaceChecks(editor, clear: clear, type: type, check: check)

    clear(); type("**加粗** 和 *斜体* [参考](https://example.com)")
    let liveBold = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let italicRange = (editor.string as NSString).range(of: "斜体"), linkRange = (editor.string as NSString).range(of: "参考")
    let liveItalic = editor.textStorage?.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
    let liveSlant = editor.textStorage?.attribute(.obliqueness, at: italicRange.location, effectiveRange: nil) as? Double ?? 0
    try check(editor.string == "加粗 和 斜体 参考" && liveBold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true && liveItalic.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) || liveSlant != 0 } == true, "Markdown emphasis formats live without changing earlier spans")
    try check(editor.textStorage?.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"), "Markdown link input creates a clickable link")
    editor.setSelectedRange(italicRange); editor.copy(nil)
    let italicClipboard = try NSAttributedString(data: board.data(forType: .rtf)!, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    let italicClipboardFont = italicClipboard.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    try check(italicClipboardFont.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true && board.string(forType: .html)?.contains("<em>") == true, "Chinese emphasis copies with standard RTF and HTML italic markers")
    editor.copyMarkdown(nil)
    editor.toggleItalics(nil)
    let clearedItalic = editor.textStorage?.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
    let clearedSlant = editor.textStorage?.attribute(.obliqueness, at: italicRange.location, effectiveRange: nil) as? Double ?? 0
    try check(board.string(forType: .string) == "*斜体*" && clearedSlant == 0 && clearedItalic.map { !NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true, "Chinese emphasis copies as Markdown and can be turned off")

    clear(); type("文字 **bold*"); editor.undoManager?.removeAllActions(); type("*")
    if let manager = editor.undoManager {
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }; manager.undo()
        try check(editor.string == "文字 **bold*", "live Markdown conversion can be undone with the triggering keystroke")
    }

    clear(); type("- [ ] 待办"); editor.insertNewline(nil); type("下一项")
    try check(editor.string == "☐ 待办\n☐ 下一项", "typed Markdown task list converts and continues on Return")

    for prefix in ["- [] ", "* [] ", "+ [] ", "[ ] ", "[x] ", "- [X] "] {
        clear(); type(prefix + "任务")
        try check(editor.string == (prefix.lowercased().contains("[x]") ? "☑ 任务" : "☐ 任务"), "task shorthand \(prefix.debugDescription) converts live")
    }
    clear(); type("- [] 主任务"); editor.insertNewline(nil); editor.insertTab(nil); type("子任务")
    try check(editor.string == "☐ 主任务\n  ☐ 子任务", "Tab indents a task without inserting a literal tab")
    let taskStyle = editor.textStorage?.attribute(.paragraphStyle, at: (editor.string as NSString).range(of: "子任务").location, effectiveRange: nil) as? NSParagraphStyle
    try check((taskStyle?.headIndent ?? 0) > (taskStyle?.firstLineHeadIndent ?? 0) + 10, "wrapped task text uses a hanging indent")
    editor.toggleCheck(nil)
    try check(editor.string.hasSuffix("  ☑ 子任务"), "an indented task can be completed")
    let completedIndex = (editor.string as NSString).range(of: "子任务").location
    try check(editor.layoutManager?.temporaryAttribute(.strikethroughStyle, atCharacterIndex: completedIndex, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue && editor.textStorage?.attribute(.strikethroughStyle, at: completedIndex, effectiveRange: nil) == nil, "completion styling is visible without changing stored text formatting")
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length)); editor.copyMarkdown(nil)
    try check(board.string(forType: .string) == "- [ ] 主任务\n    - [x] 子任务", "copying a completed task as Markdown retains state without adding strikethrough")
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)); editor.insertNewline(nil)
    try check(editor.string.hasSuffix("\n  ☐ "), "a completed nested task continues as an unchecked task at the same depth")
    editor.insertNewline(nil)
    try check(editor.string.hasSuffix("\n☐ "), "Return on an empty nested task outdents one level")
    editor.insertNewline(nil); type("正文")
    try check(editor.string.hasSuffix("\n正文"), "Return on an empty root task exits the checklist")

    clear(); type("> 引用"); editor.insertNewline(nil); type("第二行"); editor.insertNewline(nil); editor.insertNewline(nil); type("正文")
    try check(editor.string == "› 引用\n› 第二行\n正文", "typed quotes continue on Return and an empty quote returns to body text")

    clear(); type("- [] "); type("可撤销"); editor.undoManager?.removeAllActions(); editor.toggleCheck(nil)
    if let manager = editor.undoManager {
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }; manager.undo()
        try check(editor.string == "☐ 可撤销" && editor.layoutManager?.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 2, effectiveRange: nil) == nil, "undoing completion restores both state and appearance")
        manager.redo()
        try check(editor.string == "☑ 可撤销", "redo restores task completion")
    }
    try check(controller.flush(), "the styled checklist saves successfully")
    let reopenedTask = try NoteWindowController(note: store.note(note.id)!, store: store, app: delegate)
    try check(reopenedTask.editor.string == "☑ 可撤销" && reopenedTask.editor.listControlRects().count == 1, "saved checklists reopen with their checkbox controls")
    reopenedTask.window?.orderOut(nil)

    clear(); type("1) 第一项"); editor.insertNewline(nil); type("第二项")
    try check(editor.string == "1. 第一项\n2. 第二项", "typed Markdown numbered list continues on Return")

    clear(); board.clearContents(); board.setString("# 剪贴板\n- 项目\n- [x] 完成\n\n**加粗**", forType: .string); editor.paste(nil)
    try check(editor.string == "剪贴板\n• 项目\n☑ 完成\n加粗" && (editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 25, "plain Markdown clipboard text pastes as formatted content")
    let markdownPasted = editor.attributedString()
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length)); editor.copy(nil)
    let outgoingHTML = try ClipboardImporter.html(board.string(forType: .html)!)
    try check(outgoingHTML.string.contains("• 项目") && !outgoingHTML.string.contains("• •") && (outgoingHTML.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 25, "HTML-only paste targets receive real headings and one list marker")
    let outgoingRTF = try NSAttributedString(data: board.data(forType: .rtf)!, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    try check(outgoingRTF.string == editor.string && (outgoingRTF.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 25, "RTF-only paste targets retain the text and heading font")
    editor.copyMarkdown(nil)
    try check(board.string(forType: .string)?.contains("# 剪贴板") == true && board.string(forType: .string)?.contains("- [x] 完成") == true && board.string(forType: .string)?.contains("**加粗**") == true, "Copy as Markdown exposes readable Markdown syntax")
    clear(); editor.pasteMarkdown(nil)
    try check(editor.string == markdownPasted.string, "explicit Markdown paste renders copied Markdown again")
    if let manager = editor.undoManager {
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }; manager.undo()
        try check(editor.string.isEmpty, "one undo removes an explicit Markdown paste")
        manager.redo()
        try check(editor.string == markdownPasted.string && (editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 25, "redo restores Markdown content and its heading style")
    }

    clear(); board.clearContents(); board.setString("# 保留原文\n**字面符号**", forType: .string); editor.pasteAsPlainText(nil)
    try check(editor.string == "# 保留原文\n**字面符号**", "paste and match style preserves literal Markdown source")

    clear()
    let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
    board.clearContents(); board.writeObjects([image]); editor.paste(nil)
    try check(editor.attributedString().containsAttachments, "native image paste inserts an attachment")
    let mixed = NSMutableAttributedString(string: "图文混合\n", attributes: RichTextView.bodyAttributes)
    mixed.append(editor.attributedString()); mixed.append(NSAttributedString(string: "图片后的文字", attributes: RichTextView.bodyAttributes))
    clear(); board.clearContents(); board.setData(try NoteStore.encodeContent(mixed), forType: .rtfd); editor.paste(nil)
    try check(editor.string.contains("图文混合") && editor.string.contains("图片后的文字") && editor.attributedString().containsAttachments, "RTFD paste preserves mixed text and image order")
    try check(controller.flush(), "controller flush saves live content")
    try check(try store.content(note.id).containsAttachments, "pasted image survives disk round trip")
    let savedFrame = controller.window!.frame
    let reopened = try NoteWindowController(note: store.note(note.id)!, store: store, app: delegate)
    try check(reopened.window!.frame == savedFrame, "window size stays stable across restoration")
    reopened.window?.orderOut(nil)

    clear(); editor.insertText("任务", replacementRange: editor.selectedRange()); editor.checklist(nil)
    try check(editor.string == "☐ 任务", "checklist inserts a readable item")
    editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.toggleCheck(nil)
    try check(editor.string == "☑ 任务", "checklist toggles completion")
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)); editor.insertNewline(nil)
    try check(editor.string.hasSuffix("\n☐ "), "Return continues the checklist")

    clear(); editor.insertText("撤销验证", replacementRange: editor.selectedRange())
    editor.undoManager?.removeAllActions()
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length)); editor.toggleBoldface(nil)
    try check(editor.string == "撤销验证", "formatting preserves text")
    if let manager = editor.undoManager {
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }
        manager.undo()
        let font = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check(!(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false), "formatting can be undone")
    } else { throw SmokeFailure.assertion("editor needs an undo manager") }

    try check(controller.window?.level == .normal && store.note(note.id)?.isPinned == false, "new note starts without pinning")
    controller.togglePin(nil)
    try check(controller.window?.level == .floating && store.note(note.id)?.isPinned == true, "pin updates window and saved state")
    try check(controller.window?.collectionBehavior.contains(.managed) == true && controller.window?.collectionBehavior.contains(.canJoinAllSpaces) == false, "pinned window is managed in one Space")
    controller.togglePin(nil)
    try check(controller.window?.level == .normal && store.note(note.id)?.isPinned == false, "unpin updates window and saved state")
    controller.window?.performClose(nil)
    try check(controller.window?.isVisible == false && store.note(note.id)?.isVisible == false && store.note(note.id)?.isDeleted == false, "close hides a note without deleting content")
    print("Native integration checks completed.")
}
