import AppKit

/// Foundation parses Markdown; we materialize its semantic attributes into ordinary AppKit
/// text, so headings and list markers survive the app's RTFD storage and normal copy/paste.
public enum MarkdownFormatter {
    public static var bodyAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 5; style.paragraphSpacing = 5
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }

    public static func inline(_ source: String, attributes: [NSAttributedString.Key: Any]) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            result.append(NSAttributedString(string: text, attributes: styled(attributes, intent: run.inlinePresentationIntent, link: run.link)))
        }
        return result
    }

    /// Ordinary clipboard text retains its exact whitespace. Only recognized Markdown is parsed.
    public static func documentIfMarkdown(_ source: String) throws -> NSAttributedString? {
        let parsed = try AttributedString(markdown: source)
        guard canRender(parsed), hasFormatting(parsed) else { return nil }
        return render(parsed, source: source)
    }

    public static func document(_ source: String) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: source)
        guard canRender(parsed) else { return NSAttributedString(string: source, attributes: bodyAttributes) }
        return render(parsed, source: source)
    }

    private static func canRender(_ parsed: AttributedString) -> Bool {
        for run in parsed.runs {
            // Image URLs and tables stay as source text rather than silently losing content.
            if run.imageURL != nil { return false }
            for component in run.presentationIntent?.components ?? [] {
                if case .table = component.kind { return false }
            }
        }
        return true
    }

    private static func hasFormatting(_ parsed: AttributedString) -> Bool {
        for run in parsed.runs {
            if run.link != nil { return true }
            if let inline = run.inlinePresentationIntent,
               !inline.intersection([.stronglyEmphasized, .emphasized, .code, .strikethrough]).isEmpty { return true }
            for component in run.presentationIntent?.components ?? [] {
                switch component.kind {
                case .header, .orderedList, .unorderedList, .blockQuote, .codeBlock: return true
                default: break
                }
            }
        }
        return false
    }

    private static func render(_ parsed: AttributedString, source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var blockID: Int?, seenItems: Set<Int> = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let nextBlock = components.first?.identity
            let startingBlock = result.length == 0 || nextBlock != blockID
            var attrs = bodyAttributes
            var codeBlock = false
            let quoteDepth = components.filter { $0.kind == .blockQuote }.count
            for component in components {
                switch component.kind {
                case .header(let level): attrs[.font] = NSFont.systemFont(ofSize: level == 1 ? 25 : 19, weight: .bold)
                case .codeBlock: codeBlock = true; attrs[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                default: break
                }
            }
            var text = String(parsed[run.range].characters)
            if startingBlock {
                if result.length > 0 && !result.string.hasSuffix("\n") {
                    result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
                }
                if quoteDepth > 0 { result.append(NSAttributedString(string: String(repeating: "› ", count: quoteDepth), attributes: attrs)) }
                let lists = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
                // An empty parent list item may have no text run of its own. Keep its marker
                // before rendering the child, instead of dropping that part of the document.
                let items = components.enumerated().filter { if case .listItem = $0.element.kind { return true }; return false }
                for parent in items.dropFirst().reversed() where !seenItems.contains(parent.element.identity) {
                    guard case .listItem(let ordinal) = parent.element.kind else { continue }
                    let owners = components.dropFirst(parent.offset + 1).filter { $0.kind == .orderedList || $0.kind == .unorderedList }
                    let indent = String(repeating: "  ", count: max(0, owners.count - 1))
                    let marker = owners.first?.kind == .orderedList ? "\(ordinal). " : "• "
                    result.append(NSAttributedString(string: indent + marker + "\n", attributes: bodyAttributes))
                    seenItems.insert(parent.element.identity)
                }
                if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
                   case .listItem(let ordinal) = item.kind {
                    let indent = String(repeating: "  ", count: max(0, lists.count - 1))
                    if seenItems.insert(item.identity).inserted {
                        var marker = lists.first?.kind == .orderedList ? "\(ordinal). " : "• "
                        for (token, taskMarker) in [("[]", "☐ "), ("[ ]", "☐ "), ("[x]", "☑ "), ("[X]", "☑ ")] {
                            if text == token || text.hasPrefix(token + " ") {
                                marker = taskMarker; text.removeFirst(token.count)
                                if text.hasPrefix(" ") { text.removeFirst() }
                                break
                            }
                        }
                        result.append(NSAttributedString(string: indent + marker, attributes: attrs))
                    } else { result.append(NSAttributedString(string: indent + "  ", attributes: attrs)) }
                }
            }
            blockID = nextBlock
            let inlineIntent = run.inlinePresentationIntent ?? []
            if inlineIntent.contains(.softBreak) || inlineIntent.contains(.lineBreak) { text = "\n" + String(repeating: "› ", count: quoteDepth) }
            var runAttributes = styled(attrs, intent: inlineIntent, link: run.link)
            if codeBlock { runAttributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.08) }
            result.append(NSAttributedString(string: text, attributes: runAttributes))
        }
        let trailingNewlines = source.reversed().prefix { $0 == "\n" }.count
        let existingNewlines = result.string.reversed().prefix { $0 == "\n" }.count
        if trailingNewlines > existingNewlines {
            result.append(NSAttributedString(string: String(repeating: "\n", count: trailingNewlines - existingNewlines), attributes: bodyAttributes))
        }
        let text = result.string as NSString
        var offset = 0
        while offset < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: offset, length: 0))
            result.addAttribute(.paragraphStyle, value: TextList.paragraphStyle(for: result.attributedSubstring(from: paragraph)), range: paragraph)
            offset = NSMaxRange(paragraph)
        }
        return result
    }

    private static func styled(_ base: [NSAttributedString.Key: Any], intent: InlinePresentationIntent?, link: URL?) -> [NSAttributedString.Key: Any] {
        var attributes = base
        let intent = intent ?? []
        let original = attributes[.font] as? NSFont ?? .systemFont(ofSize: 15)
        let originalTraits = NSFontManager.shared.traits(of: original)
        // Chinese keyboard input may use PingFang directly, which has no italic face. A system
        // font preserves the requested traits and lets AppKit choose the appropriate glyphs.
        var font = originalTraits.contains(.fixedPitchFontMask) ? NSFont.monospacedSystemFont(ofSize: original.pointSize, weight: .regular) : NSFont.systemFont(ofSize: original.pointSize)
        var traits = originalTraits.intersection([.boldFontMask, .italicFontMask])
        if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
        if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
        if intent.contains(.code) {
            font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
        }
        attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits)
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link, let scheme = link.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) { attributes[.link] = link }
        return attributes
    }
}
