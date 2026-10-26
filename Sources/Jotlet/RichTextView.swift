import AppKit
import UniformTypeIdentifiers
import JotletCore

final class RichTextView: NSTextView {
    var previewImage: ((NSImage) -> Void)?
    private var refreshingPresentation = false
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        MarkdownFormatter.bodyAttributes
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawListControls(in: dirtyRect)
        if string.isEmpty {
            ("写点什么，或粘贴一张截图…" as NSString).draw(
                at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor])
        }
    }

    override func didChangeText() {
        refreshPresentation()
        super.didChangeText()
    }

    /// Completion is a display state. Temporary attributes never leak into saved text,
    /// copied Markdown or the user's own strikethrough formatting.
    func refreshPresentation() {
        guard !refreshingPresentation, let storage = textStorage, let layout = layoutManager else { return }
        refreshingPresentation = true
        defer { refreshingPresentation = false }
        let fullRange = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.foregroundColor, .strikethroughStyle, .strikethroughColor] {
            layout.removeTemporaryAttribute(key, forCharacterRange: fullRange)
        }
        let text = storage.string as NSString
        var offset = 0
        storage.beginEditing()
        while offset < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: offset, length: 0))
            let line = storage.attributedSubstring(from: paragraph)
            let style = TextList.paragraphStyle(for: line)
            if (storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.isEqual(style) != true {
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
            if let list = TextList.parse(line) {
                let marker = NSRange(location: offset + list.markerRange.location, length: list.isQuote ? list.markerRange.length - 1 : 1)
                if list.isTask || list.isQuote {
                    layout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: marker)
                }
                if list.isCompleted {
                    let body = NSRange(location: offset + list.prefixRange.length, length: max(0, paragraph.length - list.prefixRange.length))
                    layout.addTemporaryAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                                   .strikethroughColor: NSColor.tertiaryLabelColor], forCharacterRange: body)
                }
            }
            offset = NSMaxRange(paragraph)
        }
        storage.endEditing()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Rectangles are computed from TextKit, so scrolling, wrapping and resizing share
    /// exactly the same geometry as the text and its click targets.
    func listControlRects() -> [(range: NSRange, rect: NSRect, list: TextList)] {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return [] }
        layout.ensureLayout(for: container)
        let text = string as NSString
        var result: [(NSRange, NSRect, TextList)] = [], offset = 0
        while offset < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: offset, length: 0))
            if let list = TextList.parse(storage.attributedSubstring(from: paragraph)), list.isTask || list.isQuote {
                let marker = NSRange(location: offset + list.markerRange.location, length: 1)
                let glyphs = layout.glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
                var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
                let font = storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
                let line = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let baseline = line.minY + layout.location(forGlyphAt: glyphs.location).y + textContainerOrigin.y
                let side: CGFloat = 14
                rect = NSRect(x: floor(rect.midX - side / 2), y: floor(baseline - font.capHeight / 2 - side / 2), width: side, height: side)
                if list.isQuote {
                    let allGlyphs = layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
                    let block = layout.boundingRect(forGlyphRange: allGlyphs, in: container)
                    rect = NSRect(x: rect.minX + 4, y: block.minY + textContainerOrigin.y + 2, width: 3, height: max(16, block.height - 4))
                    let step = NSAttributedString(string: "› ", attributes: storage.attributes(at: marker.location, effectiveRange: nil)).size().width
                    for depth in 1..<(list.marker.count / 2) {
                        result.append((marker, rect.offsetBy(dx: CGFloat(depth) * step, dy: 0), list))
                    }
                }
                result.append((marker, rect, list))
            }
            offset = NSMaxRange(paragraph)
        }
        return result
    }

    private func drawListControls(in dirtyRect: NSRect) {
        for control in listControlRects() where control.rect.intersects(dirtyRect) {
            if control.list.isQuote {
                NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: control.rect, xRadius: 1.5, yRadius: 1.5).fill()
                continue
            }
            let box = NSBezierPath(roundedRect: control.rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            if control.list.isCompleted {
                NSColor.controlAccentColor.setFill(); box.fill()
                let check = NSBezierPath(); check.lineWidth = 1.6; check.lineCapStyle = .round; check.lineJoinStyle = .round
                let rect = control.rect
                check.move(to: NSPoint(x: rect.minX + 3.6, y: rect.minY + 7.2))
                check.line(to: NSPoint(x: rect.minX + 6.1, y: rect.minY + 9.6))
                check.line(to: NSPoint(x: rect.minX + 10.4, y: rect.minY + 4.5))
                NSColor.white.setStroke(); check.stroke()
            } else {
                NSColor.textBackgroundColor.setFill(); box.fill()
                NSColor.secondaryLabelColor.withAlphaComponent(0.65).setStroke(); box.lineWidth = 1.25; box.stroke()
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for control in listControlRects() where control.list.isTask {
            addCursorRect(control.rect.insetBy(dx: -3, dy: -3), cursor: .pointingHand)
        }
    }

    func replace(_ range: NSRange, with content: NSAttributedString, preservingSelection: Bool = false) {
        let selection = selectedRange()
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        guard performValidatedReplacement(in: range, with: RichTextStyles.preservingItalic(content)) else { return }
        if preservingSelection {
            setSelectedRange(NSRange(location: min(selection.location, (string as NSString).length),
                                     length: min(selection.length, max(0, (string as NSString).length - selection.location))))
        } else { setSelectedRange(NSRange(location: range.location + content.length, length: 0)) }
        needsDisplay = true
    }

    @objc func toggleBoldface(_ sender: Any?) { toggleFontTrait(.boldFontMask) }
    @objc func toggleItalics(_ sender: Any?) { toggleFontTrait(.italicFontMask) }
    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        let selection = selectedRange()
        let first = selection.length > 0 ? textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont : typingAttributes[.font] as? NSFont
        let slant = selection.length > 0 ? textStorage?.attribute(.obliqueness, at: selection.location, effectiveRange: nil) as? Double : typingAttributes[.obliqueness] as? Double
        let removing = NSFontManager.shared.traits(of: first ?? .systemFont(ofSize: 15)).contains(trait) || (trait == .italicFontMask && (slant ?? 0) != 0)
        func convert(_ font: NSFont) -> NSFont {
            if trait == .italicFontMask {
                var traits = NSFontManager.shared.traits(of: font).intersection(.boldFontMask)
                if !removing { traits.insert(.italicFontMask) }
                return NSFontManager.shared.convert(NSFont.systemFont(ofSize: font.pointSize), toHaveTrait: traits)
            }
            return removing ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait)
        }
        if selection.length > 0, let storage = textStorage {
            let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
            result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { font, range, _ in
                result.addAttribute(.font, value: convert(font as? NSFont ?? .systemFont(ofSize: 15)), range: range)
            }
            if trait == .italicFontMask { result.addAttribute(.obliqueness, value: 0.0, range: NSRange(location: 0, length: result.length)) }
            replace(selection, with: result, preservingSelection: true)
        } else {
            typingAttributes[.font] = convert(first ?? .systemFont(ofSize: 15))
            if trait == .italicFontMask {
                typingAttributes[.font] = NSFontManager.shared.convert(typingAttributes[.font] as! NSFont, toNotHaveTrait: .italicFontMask)
                if removing { typingAttributes[.obliqueness] = 0.0 }
                else { typingAttributes[.obliqueness] = 0.18 }
            }
        }
        window?.makeFirstResponder(self)
    }
    @objc func toggleUnderline(_ sender: Any?) {
        let selection = selectedRange()
        let first = selection.length > 0 ? textStorage?.attribute(.underlineStyle, at: selection.location, effectiveRange: nil) : typingAttributes[.underlineStyle]
        let value = (first as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
        if selection.length > 0, let storage = textStorage {
            let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
            result.addAttribute(.underlineStyle, value: value, range: NSRange(location: 0, length: result.length))
            replace(selection, with: result, preservingSelection: true)
        } else { typingAttributes[.underlineStyle] = value }
        window?.makeFirstResponder(self)
    }

    @objc func heading(_ sender: NSPopUpButton) {
        let size: CGFloat = [15, 25, 19][min(sender.indexOfSelectedItem, 2)]
        let font = NSFont.systemFont(ofSize: size, weight: size == 15 ? .regular : .semibold)
        let ns = string as NSString
        let range = ns.paragraphRange(for: selectedRange())
        if range.length > 0, let storage = textStorage {
            let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            text.addAttribute(.font, value: font, range: NSRange(location: 0, length: text.length))
            replace(range, with: text, preservingSelection: true)
        }
        typingAttributes[.font] = font
        window?.makeFirstResponder(self)
    }

    @objc func bulletList(_ sender: Any?) { setList(kind: "bullet") }
    @objc func numberedList(_ sender: Any?) { setList(kind: "numbered") }
    @objc func checklist(_ sender: Any?) { setList(kind: "check") }
    private func setList(kind: String) {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let range = ns.paragraphRange(for: selectedRange())
        let selected = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let lines = selected.string.components(separatedBy: "\n")
        var offset = 0
        var replacements: [(NSRange, String)] = []
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 && line.isEmpty && !replacements.isEmpty { break }
            let length = (line as NSString).length
            let list = TextList.parse(line)
            let prefix = kind == "bullet" ? "• " : kind == "check" ? "☐ " : "\(index + 1). "
            let sameKind = kind == "bullet" ? list?.marker == "• " : kind == "check" ? list?.isTask == true : list?.marker.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil
            replacements.append((NSRange(location: offset + (list?.markerRange.location ?? 0), length: list?.markerRange.length ?? 0), sameKind ? "" : prefix))
            offset += length + 1
        }
        for (range, prefix) in replacements.reversed() {
            selected.replaceCharacters(in: range, with: NSAttributedString(string: prefix, attributes: Self.bodyAttributes))
        }
        replace(range, with: selected)
        if selected.length > 0 { setSelectedRange(NSRange(location: range.location + selected.length, length: 0)) }
        window?.makeFirstResponder(self)
    }

    @objc func toggleCheck(_ sender: Any?) {
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: selectedRange())
        guard let list = TextList.parse(ns.substring(with: paragraph)), list.isTask else { return }
        let start = paragraph.location + list.markerRange.location
        let mark = ns.substring(with: NSRange(location: start, length: 1))
        let attributes = textStorage?.attributes(at: start, effectiveRange: nil) ?? Self.bodyAttributes
        replace(NSRange(location: start, length: 1), with: NSAttributedString(string: mark == "☐" ? "☑" : "☐", attributes: attributes), preservingSelection: true)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let composing = hasMarkedText()
        super.insertText(insertString, replacementRange: replacementRange)
        guard !composing, !hasMarkedText(), let inserted = insertString as? String, inserted.count == 1,
              [" ", "*", "_", "`", "~", ")"].contains(inserted), selectedRange().length == 0 else { return }
        applyMarkdownShortcut()
    }

    private func applyMarkdownShortcut() {
        guard let storage = textStorage else { return }
        let caret = selectedRange().location
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: caret, length: 0))
        let range = NSRange(location: paragraph.location, length: caret - paragraph.location)
        guard range.length > 0, range.length < 8192 else { return }
        let prefix = (string as NSString).substring(with: range)
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        if let font = attributes[.font] as? NSFont, NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) { return }
        attributes.removeValue(forKey: .link)
        if prefix.range(of: "^#{1,6} $", options: .regularExpression) != nil {
            let level = prefix.count - 1
            breakUndoCoalescing()
            replace(range, with: NSAttributedString(string: ""))
            attributes[.font] = NSFont.systemFont(ofSize: level == 1 ? 25 : 19, weight: .bold)
            typingAttributes = attributes
            return
        }
        if prefix.range(of: "^ *(?:[-+*•] )?\\[(?: |x|X)?\\] $", options: .regularExpression) != nil {
            let completed = prefix.contains("[x]") || prefix.contains("[X]")
            let indent = String(prefix.prefix { $0 == " " })
            breakUndoCoalescing()
            replace(range, with: NSAttributedString(string: indent + (completed ? "☑ " : "☐ "), attributes: attributes))
            typingAttributes = attributes
            return
        }
        if prefix.range(of: "^ *[-+*] $", options: .regularExpression) != nil {
            breakUndoCoalescing()
            replace(range, with: NSAttributedString(string: String(prefix.prefix { $0 == " " }) + "• ", attributes: attributes))
            typingAttributes = attributes
            return
        }
        if prefix == "> " {
            breakUndoCoalescing()
            replace(range, with: NSAttributedString(string: "› ", attributes: attributes))
            typingAttributes = attributes
            return
        }
        if prefix.range(of: "^ *[0-9]+\\) $", options: .regularExpression) != nil {
            breakUndoCoalescing()
            replace(range, with: NSAttributedString(string: prefix.replacingOccurrences(of: ")", with: "."), attributes: attributes))
            typingAttributes = attributes
            return
        }
        let patterns = [
            #"(?<![\\*])\*\*[^\n]+\*\*$"#,
            #"(?<![\\_])__[^\n]+__$"#,
            #"(?<![\\*])\*(?!\*)[^*\n]+(?<!\\)\*$"#,
            #"(?<![\\_])_(?!_)[^_\n]+(?<!\\)_$"#,
            #"(?<![\\`])`[^`\n]+`$"#,
            #"(?<![\\~])~~[^\n]+~~$"#,
            #"(?<![!\\])\[[^\]\n]+\]\([^\n)]+\)$"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: range.length)) else { continue }
            let token = (prefix as NSString).substring(with: match.range)
            let tokenRange = NSRange(location: range.location + match.range.location, length: match.range.length)
            var base = storage.attributes(at: tokenRange.location, effectiveRange: nil); base.removeValue(forKey: .link)
            guard let formatted = try? MarkdownFormatter.inline(token, attributes: base), formatted.string != token,
                  !formatted.string.isEmpty else { continue }
            breakUndoCoalescing()
            replace(tokenRange, with: formatted)
            typingAttributes = base
            detectLinks()
            return
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText(), let storage = textStorage else {
            super.deleteBackward(sender); return
        }
        let paragraph = (string as NSString).paragraphRange(for: selection)
        let line = storage.attributedSubstring(from: paragraph)
        let relativeCaret = selection.location - paragraph.location

        // Markers are portable document text, but behave as one editable block prefix.
        // At a nested prefix, Backspace lifts one level before removing the block.
        if let list = TextList.parse(line), relativeCaret <= list.prefixRange.length {
            let count: Int
            if !list.indentation.isEmpty { count = min(2, list.indentation.count) }
            else if list.isQuote && list.markerRange.length > 2 { count = 2 }
            else { count = list.prefixRange.length }
            let oldTyping = typingAttributes
            breakUndoCoalescing()
            undoManager?.beginUndoGrouping()
            replace(NSRange(location: paragraph.location, length: count), with: NSAttributedString(string: ""))
            setSelectedRange(NSRange(location: paragraph.location + max(0, relativeCaret - count), length: 0))
            var attributes = oldTyping
            attributes[.paragraphStyle] = Self.bodyAttributes[.paragraphStyle]
            if paragraph.location < storage.length {
                attributes[.paragraphStyle] = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            }
            setTypingAttributesUndoably(attributes, previous: oldTyping)
            undoManager?.setActionName("退出段落格式")
            undoManager?.endUndoGrouping()
            return
        }

        guard relativeCaret == 0 else { super.deleteBackward(sender); return }
        let empty = line.string.trimmingCharacters(in: .newlines).isEmpty
        let font = (empty ? typingAttributes[.font] : line.attribute(.font, at: 0, effectiveRange: nil)) as? NSFont
        let heading = (font?.pointSize ?? 15) >= 19
        guard heading || (empty && hasTypingFormat) else { super.deleteBackward(sender); return }

        let oldTyping = typingAttributes
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        if line.length > 0 {
            let body = NSMutableAttributedString(attributedString: line)
            body.enumerateAttribute(.font, in: NSRange(location: 0, length: body.length)) { value, range, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: 15)
                let traits = NSFontManager.shared.traits(of: font)
                let base = traits.contains(.fixedPitchFontMask) ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : NSFont.systemFont(ofSize: 15)
                var preservedTraits = traits.intersection([.boldFontMask, .italicFontMask])
                if font.pointSize >= 19 { preservedTraits.remove(.boldFontMask) }
                body.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: preservedTraits), range: range)
            }
            if empty { body.setAttributes(Self.bodyAttributes, range: NSRange(location: 0, length: body.length)) }
            replace(paragraph, with: body, preservingSelection: true)
        }
        var attributes = Self.bodyAttributes
        if !empty, paragraph.location < storage.length { attributes = storage.attributes(at: paragraph.location, effectiveRange: nil) }
        setTypingAttributesUndoably(attributes, previous: oldTyping)
        undoManager?.setActionName("取消段落格式")
        undoManager?.endUndoGrouping()
    }

    private var hasTypingFormat: Bool {
        let font = typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 15)
        let traits = NSFontManager.shared.traits(of: font)
        return !traits.intersection([.boldFontMask, .italicFontMask, .fixedPitchFontMask]).isEmpty ||
            (typingAttributes[.obliqueness] as? Double ?? 0) != 0 ||
            (typingAttributes[.underlineStyle] as? Int ?? 0) != 0 ||
            (typingAttributes[.strikethroughStyle] as? Int ?? 0) != 0 || typingAttributes[.link] != nil
    }

    private func setTypingAttributesUndoably(_ attributes: [NSAttributedString.Key: Any], previous: [NSAttributedString.Key: Any]? = nil) {
        let old = previous ?? typingAttributes
        undoManager?.registerUndo(withTarget: self) { $0.setTypingAttributesUndoably(old) }
        typingAttributes = attributes
        needsDisplay = true
    }

    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() { super.insertNewline(sender); return }
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: selectedRange())
        let line = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
        guard let list = TextList.parse(line) else {
            super.insertNewline(sender); typingAttributes = Self.bodyAttributes; return
        }
        let prefix = list.indentation + list.marker
        if line == prefix {
            if !list.indentation.isEmpty { insertBacktab(sender) }
            else {
                replace(NSRange(location: paragraph.location, length: (prefix as NSString).length), with: NSAttributedString(string: ""))
                typingAttributes = Self.bodyAttributes
            }
            return
        }
        undoManager?.beginUndoGrouping()
        super.insertNewline(sender)
        let next: String
        if list.isTask { next = list.indentation + "☐ " }
        else if let number = Int(list.marker.dropLast(2)) {
            next = list.indentation + "\(number + 1). "
        } else { next = prefix }
        insertText(next, replacementRange: selectedRange())
        undoManager?.endUndoGrouping()
    }

    override func insertTab(_ sender: Any?) {
        if !indentList(outdent: false) { super.insertTab(sender) }
    }
    override func insertBacktab(_ sender: Any?) {
        if !indentList(outdent: true) { super.insertBacktab(sender) }
    }
    private func indentList(outdent: Bool) -> Bool {
        guard let storage = textStorage, !hasMarkedText() else { return false }
        let selection = selectedRange()
        let range = (string as NSString).paragraphRange(for: selection)
        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let ns = result.string as NSString
        var offset = 0, edits: [(NSRange, String)] = []
        while offset < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: offset, length: 0))
            guard let list = TextList.parse(ns.substring(with: paragraph)), !list.isQuote else { return false }
            edits.append((NSRange(location: offset, length: outdent ? min(2, list.indentation.count) : 0), outdent ? "" : "  "))
            offset = NSMaxRange(paragraph)
        }
        guard !edits.isEmpty else { return false }
        for (edit, prefix) in edits.reversed() { result.replaceCharacters(in: edit, with: NSAttributedString(string: prefix, attributes: Self.bodyAttributes)) }
        breakUndoCoalescing()
        replace(range, with: result)
        func mapped(_ index: Int) -> Int {
            index + edits.filter { range.location + $0.0.location <= index }.reduce(0) { $0 + ($1.1 as NSString).length - $1.0.length }
        }
        let start = max(range.location, mapped(selection.location)), end = max(range.location, mapped(NSMaxRange(selection)))
        setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let task = listControlRects().first(where: { $0.list.isTask && $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) {
            let selection = selectedRange()
            let oldTyping = typingAttributes
            setSelectedRange(NSRange(location: task.range.location, length: 0)); toggleCheck(nil)
            setSelectedRange(selection); typingAttributes = oldTyping
            return
        }
        let index = contentIndex(at: point)
        if index < (string as NSString).length {
            if event.clickCount == 2, let image = image(at: index) { previewImage?(image); return }
        }
        super.mouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        let selection = selectedRange()
        if selection.length > 0, let text = textStorage?.attributedSubstring(from: selection) {
            let portable = RichTextStyles.clipboardContent(text)
            let board = NSPasteboard.general
            if let rtf = try? portable.data(from: NSRange(location: 0, length: portable.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { board.setData(rtf, forType: .rtf) }
            if portable.containsAttachments, let rtfd = try? NoteStore.encodeContent(portable) { board.setData(rtfd, forType: .rtfd) }
            board.setString(HTMLExporter.fragment(text), forType: .html)
        }
    }

    @objc func copyMarkdown(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0, let content = textStorage?.attributedSubstring(from: selection) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MarkdownExporter.document(content), forType: .string)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        let types = board.types ?? []
        let hasRichContent = types.contains(.rtfd) || types.contains(.rtf) || types.contains(.html)
        if !hasRichContent, let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            insertImages(images); return
        }
        let start = selectedRange().location
        let previousLength = (string as NSString).length - selectedRange().length
        undoManager?.beginUndoGrouping()
        var rich: NSAttributedString?
        for (type, documentType) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd), (.rtf, .rtf)] {
            if rich == nil, let data = board.data(forType: type) {
                rich = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil)
            }
        }
        if rich == nil, let html = board.string(forType: .html) {
            rich = try? ClipboardImporter.html(html)
        }
        if rich == nil, let plain = board.string(forType: .string) {
            rich = try? MarkdownFormatter.documentIfMarkdown(plain)
        }
        if let rich, rich.length > 0 {
            let content = ClipboardImporter.portableLists(rich)
            // insertText is an input-method API and can apply the current typing font size.
            // Validated replacement preserves the imported attributes and native undo behavior.
            replace(selectedRange(), with: content)
        }
        else { super.paste(sender) }
        let length = (string as NSString).length - previousLength
        if length > 0, let storage = textStorage {
            let range = NSRange(location: start, length: length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            storage.enumerateAttribute(.font, in: range) { value, range, _ in
                guard let old = value as? NSFont else { return }
                let traits = NSFontManager.shared.traits(of: old)
                let size: CGFloat = old.pointSize >= 19 ? min(old.pointSize, 25) : 15
                var font = traits.contains(.fixedPitchFontMask) ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
                font = NSFontManager.shared.convert(font, toHaveTrait: traits.intersection([.boldFontMask, .italicFontMask]))
                storage.addAttribute(.font, value: font, range: range)
            }
            storage.endEditing(); normalizeImages()
        }
        undoManager?.endUndoGrouping()
        detectLinks()
        needsDisplay = true
    }

    @objc func pasteMarkdown(_ sender: Any?) {
        guard let source = NSPasteboard.general.string(forType: .string),
              let formatted = try? MarkdownFormatter.document(source) else { return }
        breakUndoCoalescing()
        replace(selectedRange(), with: formatted)
        typingAttributes = Self.bodyAttributes
        detectLinks()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.compactMap { NSImage(contentsOf: $0) }
            if !images.isEmpty {
                let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
                setSelectedRange(NSRange(location: index, length: 0)); insertImages(images); return true
            }
        }
        return super.performDragOperation(sender)
    }

    func insertImages(_ images: [NSImage]) {
        let result = NSMutableAttributedString(string: "")
        for image in images {
            guard let attachment = Self.attachment(image, maxWidth: max(160, bounds.width - 44)) else { continue }
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n", attributes: Self.bodyAttributes))
        }
        if result.length > 0 { insertText(result, replacementRange: selectedRange()); typingAttributes = Self.bodyAttributes }
    }

    static func attachment(_ image: NSImage, maxWidth: CGFloat) -> NSTextAttachment? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]), let display = NSImage(data: data) else { return nil }
        let wrapper = FileWrapper(regularFileWithContents: data); wrapper.preferredFilename = "image-\(UUID().uuidString).png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        if display.size.width > maxWidth { display.size = NSSize(width: maxWidth, height: display.size.height * maxWidth / display.size.width) }
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: display)
        return attachment
    }

    func normalizeImages() {
        guard let storage = textStorage else { return }
        var replacements: [(NSRange, NSTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let image = self.image(from: attachment),
                  image.size.width > max(160, self.bounds.width - 44),
                  let new = Self.attachment(image, maxWidth: max(160, self.bounds.width - 44)) else { return }
            replacements.append((range, new))
        }
        for (range, attachment) in replacements { storage.addAttribute(.attachment, value: attachment, range: range) }
    }
    func detectLinks() {
        guard let storage = textStorage, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let range = NSRange(location: 0, length: storage.length)
        for match in detector.matches(in: storage.string, range: range) {
            if let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                storage.addAttribute(.link, value: url, range: match.range)
            }
        }
    }
    private func image(from attachment: NSTextAttachment) -> NSImage? {
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell, let image = cell.image { return image }
        if let data = attachment.fileWrapper?.regularFileContents { return NSImage(data: data) }
        return nil
    }
    private func image(at index: Int) -> NSImage? {
        guard index >= 0, index < (string as NSString).length,
              let attachment = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment else { return nil }
        return image(from: attachment)
    }
    private var selectedImageIndex: Int? {
        let index = selectedRange().location
        if image(at: index) != nil { return index }
        if selectedRange().length == 0, image(at: index - 1) != nil { return index - 1 }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let index = contentIndex(at: convert(event.locationInWindow, from: nil))
        if image(at: index) != nil {
            setSelectedRange(NSRange(location: index, length: 1))
            let actions: [(String, Selector)] = [("放大查看图片", #selector(viewImage)), ("复制图片", #selector(copyImage)), ("缩小图片", #selector(shrinkImage)), ("增大图片", #selector(growImage))]
            menu.insertItem(.separator(), at: 0)
            for (title, action) in actions.reversed() {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.insertItem(item, at: 0)
            }
        }
        return menu
    }
    @objc func viewImage(_ sender: Any?) {
        if let index = selectedImageIndex, let image = image(at: index) { previewImage?(image) }
    }
    @objc func copyImage(_ sender: Any?) {
        if let index = selectedImageIndex, let image = image(at: index) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        }
    }
    @objc func shrinkImage(_ sender: Any?) { resizeImage(by: 0.8) }
    @objc func growImage(_ sender: Any?) { resizeImage(by: 1.25) }
    private func resizeImage(by factor: CGFloat) {
        guard let index = selectedImageIndex, let old = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
              let previousImage = image(from: old), let bytes = old.fileWrapper?.regularFileContents,
              let image = NSImage(data: bytes) else { return }
        let wrapper = FileWrapper(regularFileWithContents: bytes); wrapper.preferredFilename = old.fileWrapper?.preferredFilename
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let width = min(max(min(32, previousImage.size.width), previousImage.size.width * factor), max(160, bounds.width - 44))
        image.size = NSSize(width: width, height: image.size.height * width / image.size.width)
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        replace(NSRange(location: index, length: 1), with: NSAttributedString(attachment: attachment))
        setSelectedRange(NSRange(location: index, length: 1))
    }
    private func contentIndex(at point: NSPoint) -> Int {
        guard let layout = layoutManager, let container = textContainer, layout.numberOfGlyphs > 0 else { return characterIndexForInsertion(at: point) }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs else { return (string as NSString).length }
        return layout.characterIndexForGlyph(at: glyph)
    }
}
