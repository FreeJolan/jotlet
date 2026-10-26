import AppKit
import JotletCore

/// Runs only through the guest's native integration suite, with its isolated editor.
func runBackspaceChecks(_ editor: RichTextView, clear: () -> Void, type: (String) -> Void,
                        check: (Bool, String) throws -> Void) throws {
    func caret(_ position: Int) { editor.setSelectedRange(NSRange(location: position, length: 0)) }
    func font(at position: Int) -> NSFont? { editor.textStorage?.attribute(.font, at: position, effectiveRange: nil) as? NSFont }
    func finishUndoGroup() {
        while let manager = editor.undoManager, manager.groupingLevel > 0 { manager.endUndoGrouping() }
    }

    for prefix in ["# ", "## ", "###### "] {
        clear(); type(prefix); editor.deleteBackward(nil)
        try check(editor.string.isEmpty && (editor.typingAttributes[.font] as? NSFont)?.pointSize == 15,
                  "Backspace exits an empty \(prefix.debugDescription) heading")
        type("正文")
        try check(font(at: 0)?.pointSize == 15 && !NSFontManager.shared.traits(of: font(at: 0)!).contains(.boldFontMask),
                  "typing after heading cancellation uses regular body text")
    }

    clear(); type("# "); editor.undoManager?.removeAllActions(); editor.deleteBackward(nil)
    finishUndoGroup(); editor.undoManager?.undo()
    try check((editor.typingAttributes[.font] as? NSFont)?.pointSize == 25, "undo restores an empty heading's typing format")
    editor.undoManager?.redo()
    try check((editor.typingAttributes[.font] as? NSFont)?.pointSize == 15, "redo cancels an empty heading's typing format")

    clear(); type("前文"); editor.insertNewline(nil); type("## 标题 📝")
    let start = (editor.string as NSString).range(of: "标题").location
    caret(start); editor.undoManager?.removeAllActions(); editor.deleteBackward(nil)
    try check(editor.string == "前文\n标题 📝" && font(at: start)?.pointSize == 15 && font(at: 0)?.pointSize == 15,
              "Backspace at a heading start removes its format without joining the previous paragraph")
    finishUndoGroup(); editor.undoManager?.undo()
    try check(editor.string == "前文\n标题 📝" && font(at: start)?.pointSize == 19, "undo restores a populated heading without changing its text")
    editor.undoManager?.redo()
    try check(font(at: start)?.pointSize == 15, "redo restores the body paragraph")

    clear(); type("# 标题"); editor.deleteBackward(nil)
    try check(editor.string == "标" && font(at: 0)?.pointSize == 25, "Backspace inside a heading deletes text normally")
    editor.deleteBackward(nil); editor.deleteBackward(nil); type("正文")
    try check(editor.string == "正文" && font(at: 0)?.pointSize == 15, "deleting all heading text then its format allows ordinary body typing")

    clear(); editor.replace(editor.selectedRange(), with: try MarkdownFormatter.document("## *斜体* [链接](https://example.com)"))
    caret(0); editor.deleteBackward(nil)
    let link = (editor.string as NSString).range(of: "链接")
    let italic = font(at: 0).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true || (editor.textStorage?.attribute(.obliqueness, at: 0, effectiveRange: nil) as? Double ?? 0) != 0
    try check(italic && font(at: 0)?.pointSize == 15 && editor.textStorage?.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"),
              "heading cancellation retains inline emphasis and links")

    for prefix in ["- ", "1) ", "- [] ", "- [x] ", "> "] {
        clear(); type("参考"); editor.insertNewline(nil); type(prefix + "内容 📝")
        let paragraph = (editor.string as NSString).paragraphRange(for: editor.selectedRange())
        let list = TextList.parse((editor.string as NSString).substring(with: paragraph))!
        caret(paragraph.location + list.prefixRange.length)
        editor.undoManager?.removeAllActions(); editor.deleteBackward(nil)
        try check(editor.string == "参考\n内容 📝", "Backspace removes the \(prefix.debugDescription) prefix while keeping text and paragraph boundary")
        if prefix == "- [x] " {
            try check(editor.layoutManager?.temporaryAttribute(.strikethroughStyle, atCharacterIndex: paragraph.location, effectiveRange: nil) == nil,
                      "exiting a completed task removes its completion decoration")
        }
        finishUndoGroup(); editor.undoManager?.undo()
        try check(TextList.parse((editor.string as NSString).substring(with: (editor.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0)))) != nil,
                  "undo restores the \(prefix.debugDescription) block prefix")
    }

    clear(); type("- [] 子项"); editor.insertTab(nil)
    caret(4); editor.deleteBackward(nil)
    try check(editor.string == "☐ 子项" && editor.selectedRange().location == 2, "Backspace first outdents a nested task")
    editor.deleteBackward(nil)
    try check(editor.string == "子项" && editor.selectedRange().location == 0, "the next Backspace exits the root task")

    clear(); editor.replace(editor.selectedRange(), with: try MarkdownFormatter.document("> > 引用"))
    caret(4); editor.deleteBackward(nil)
    try check(editor.string == "› 引用", "Backspace lifts one nested quote level")
    editor.deleteBackward(nil)
    try check(editor.string == "引用", "Backspace exits the final quote level")

    clear(); type("前文"); editor.insertNewline(nil); type("正文"); caret(3); editor.deleteBackward(nil)
    try check(editor.string == "前文正文", "Backspace in a normal body paragraph still joins the previous line")
    clear(); type("# 标题"); editor.setSelectedRange(NSRange(location: 0, length: 1)); editor.deleteBackward(nil)
    try check(editor.string == "题" && font(at: 0)?.pointSize == 25, "Backspace with a selection deletes the selection without cancelling the heading")

    clear(); editor.toggleBoldface(nil); editor.deleteBackward(nil); type("正文")
    try check(!NSFontManager.shared.traits(of: font(at: 0)!).contains(.boldFontMask), "Backspace clears active bold in an empty paragraph")
    clear(); editor.typingAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; editor.deleteBackward(nil); type("正文")
    try check((editor.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int ?? 0) == 0, "Backspace clears active strikethrough in an empty paragraph")

    clear(); type("# 保留"); caret(0); editor.deleteBackward(nil)
    let reopened = try NSAttributedString(data: NoteStore.encodeContent(editor.attributedString()), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    try check((reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 15 && MarkdownExporter.document(reopened) == "保留",
              "a cancelled heading saves and exports as body text")
}
