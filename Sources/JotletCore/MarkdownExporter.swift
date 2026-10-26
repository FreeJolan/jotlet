import AppKit

public enum MarkdownExporter {
    public static func document(_ content: NSAttributedString) -> String {
        let ns = content.string as NSString
        var output = "", offset = 0, wasQuote = false
        while offset < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: offset, length: 0))
            var length = paragraph.length
            while length > 0, let scalar = UnicodeScalar(ns.character(at: paragraph.location + length - 1)), CharacterSet.newlines.contains(scalar) { length -= 1 }
            var line = content.attributedSubstring(from: NSRange(location: paragraph.location, length: length))
            var quote = ""
            while line.string.hasPrefix("› "), TextList.parse(line)?.isQuote == true {
                quote += "> "
                line = line.attributedSubstring(from: NSRange(location: 2, length: line.length - 2))
            }
            // Without a blank line, CommonMark treats plain text following a quote as
            // a lazy continuation of that same quote.
            if wasQuote && quote.isEmpty && !output.hasSuffix("\n\n") { output += "\n" }
            wasQuote = !quote.isEmpty
            let plain = line.string as NSString
            let expression = try! NSRegularExpression(pattern: "^( *)([•☐☑] |[0-9]+\\. )")
            var prefix = "", bodyRange = NSRange(location: 0, length: line.length)
            if TextList.parse(line) != nil, let match = expression.firstMatch(in: line.string, range: bodyRange) {
                let indent = plain.substring(with: match.range(at: 1))
                let marker = plain.substring(with: match.range(at: 2))
                prefix = String(repeating: "    ", count: indent.count / 2) + (marker == "• " ? "- " : marker == "☐ " ? "- [ ] " : marker == "☑ " ? "- [x] " : marker)
                bodyRange = NSRange(location: NSMaxRange(match.range), length: line.length - NSMaxRange(match.range))
            }
            let font = line.length > 0 ? line.attribute(.font, at: min(bodyRange.location, line.length - 1), effectiveRange: nil) as? NSFont : nil
            let heading = (font?.pointSize ?? 0) >= 19
            if heading { prefix += (font?.pointSize ?? 0) >= 24 ? "# " : "## " }
            output += quote + prefix + inline(line.attributedSubstring(from: bodyRange), heading: heading)
            if NSMaxRange(paragraph) < ns.length || paragraph.length > length { output += "\n" }
            offset = NSMaxRange(paragraph)
        }
        return output
    }

    private static func inline(_ content: NSAttributedString, heading: Bool) -> String {
        var output = ""
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let data = HTMLExporter.imageData(attachment) { output += "![便签图片](data:image/png;base64,\(data.base64EncodedString()))" }
                return
            }
            let source = content.attributedSubstring(from: range).string
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 15)
            let traits = NSFontManager.shared.traits(of: font)
            let leading = String(source.prefix { $0.isWhitespace })
            let trailing = String(source.reversed().prefix { $0.isWhitespace }.reversed())
            let core = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if core.isEmpty { output += source; return }
            var text = escape(core)
            if traits.contains(.fixedPitchFontMask) {
                let runs = source.split(whereSeparator: { $0 != "`" }).map(\.count)
                let fence = String(repeating: "`", count: (runs.max() ?? 0) + 1)
                let pad = source.hasPrefix("`") || source.hasSuffix("`") || (source.hasPrefix(" ") && source.hasSuffix(" ")) ? " " : ""
                text = fence + pad + source + pad + fence
            }
            if traits.contains(.italicFontMask) || (attrs[.obliqueness] as? Double ?? 0) != 0 { text = "*\(text)*" }
            if traits.contains(.boldFontMask) && !heading { text = "**\(text)**" }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "~~\(text)~~" }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { text = "<u>\(text)</u>" }
            if let raw = attrs[.link] {
                let url = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                if let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    let target = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
                    text = "[\(text)](\(target))"
                }
            }
            output += traits.contains(.fixedPitchFontMask) ? text : leading + text + trailing
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        let punctuation = Set("\\`*_{}[]<>()#+-.!|~")
        return text.map { punctuation.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}
