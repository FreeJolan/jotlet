import AppKit

public enum HTMLExporter {
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func imageData(_ attachment: NSTextAttachment) -> Data? {
        if let wrapper = attachment.fileWrapper, let bytes = wrapper.regularFileContents,
           let image = NSImage(data: bytes), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff) {
            return bitmap.representation(using: .png, properties: [:])
        }
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell, let image = cell.image,
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            return bitmap.representation(using: .png, properties: [:])
        }
        return nil
    }
    public static func fragment(_ content: NSAttributedString) -> String {
        let ns = content.string as NSString
        var output = "", offset = 0
        var lists: [(kind: String, indent: Int, expected: Int)] = []
        func closeLevel() {
            if let list = lists.popLast() { output += "</li></\(list.kind)>" }
        }
        func closeList() {
            while !lists.isEmpty { closeLevel() }
        }
        func openItem(kind: String, indent: Int, number: Int) {
            while let list = lists.last, list.indent > indent { closeLevel() }
            if let list = lists.last, list.indent == indent {
                if list.kind != kind || (kind == "ol" && number != list.expected) { closeLevel() }
                else {
                    output += "</li><li>"; lists[lists.count - 1].expected = number + 1
                    return
                }
            }
            let start = kind == "ol" ? " start=\"\(number)\"" : ""
            let margin = lists.isEmpty ? indent * 10 : 12
            output += "<\(kind)\(start) style=\"margin-top:4px;margin-bottom:4px;margin-left:\(margin)px\"><li>"
            lists.append((kind, indent, number + 1))
        }
        let expression = try! NSRegularExpression(pattern: "^( *)(?:• |([0-9]+)\\. )")
        while offset < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: offset, length: 0))
            var length = paragraph.length
            while length > 0, let scalar = UnicodeScalar(ns.character(at: paragraph.location + length - 1)), CharacterSet.newlines.contains(scalar) { length -= 1 }
            var line = content.attributedSubstring(from: NSRange(location: paragraph.location, length: length))
            var quotes = 0
            while line.string.hasPrefix("› "), TextList.parse(line)?.isQuote == true {
                quotes += 1
                line = line.attributedSubstring(from: NSRange(location: 2, length: line.length - 2))
            }
            if quotes > 0 {
                closeList()
                output += String(repeating: "<blockquote style=\"border-left:3px solid #999;margin:6px 0;padding-left:12px\">", count: quotes)
            }
            if let task = TextList.parse(line), task.isTask {
                closeList()
                let body = line.attributedSubstring(from: NSRange(location: task.prefixRange.length, length: line.length - task.prefixRange.length))
                let done = task.isCompleted ? "color:#888;text-decoration:line-through;" : ""
                output += "<div style=\"margin:6px 0 6px \(task.indentation.count * 10)px\">\(task.isCompleted ? "☑" : "☐") <span style=\"\(done)\">\(inlineFragment(body))</span></div>"
                if quotes > 0 { output += String(repeating: "</blockquote>", count: quotes) }
                offset = NSMaxRange(paragraph)
                continue
            }
            let plain = line.string as NSString
            var bodyRange = NSRange(location: 0, length: line.length)
            let match = TextList.parse(line) == nil ? nil : expression.firstMatch(in: line.string, range: bodyRange)
            if let match {
                let numbered = match.range(at: 2).location != NSNotFound
                let number = numbered ? Int(plain.substring(with: match.range(at: 2))) ?? 1 : 0
                let kind = numbered ? "ol" : "ul", indent = match.range(at: 1).length
                openItem(kind: kind, indent: indent, number: number)
                bodyRange = NSRange(location: NSMaxRange(match.range), length: line.length - NSMaxRange(match.range))
            } else { closeList() }
            let font = line.length > 0 ? line.attribute(.font, at: min(bodyRange.location, line.length - 1), effectiveRange: nil) as? NSFont : nil
            let size = font?.pointSize ?? 15
            let tag = size >= 24 ? "h1" : size >= 19 ? "h2" : "div"
            let attributes = tag == "div" ? "" : " style=\"font-size:\(Int(size))px;margin:8px 0\""
            let body = inlineFragment(line.attributedSubstring(from: bodyRange))
            // Plain list items don't need a block wrapper inside <li>.
            if match != nil && tag == "div" { output += body.isEmpty ? "<br>" : body }
            else { output += "<\(tag)\(attributes)>\(body.isEmpty ? "<br>" : body)</\(tag)>" }
            if quotes > 0 { closeList(); output += String(repeating: "</blockquote>", count: quotes) }
            offset = NSMaxRange(paragraph)
        }
        closeList()
        return "<div style=\"white-space:pre-wrap;line-height:1.65\">\(output)</div>"
    }

    private static func inlineFragment(_ content: NSAttributedString) -> String {
        var output = ""
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let data = imageData(attachment) {
                    let size = attachment.attachmentCell?.cellSize() ?? .zero
                    let width = size.width > 0 ? " width=\"\(Int(size.width))\"" : ""
                    output += "<img alt=\"便签图片\"\(width) src=\"data:image/png;base64,\(data.base64EncodedString())\" style=\"max-width:100%;height:auto\">"
                }
                return
            }
            var text = escape(content.attributedSubstring(from: range).string).replacingOccurrences(of: "\n", with: "<br>\n")
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { text = "<strong>\(text)</strong>" }
                if traits.contains(.italicFontMask) || (attrs[.obliqueness] as? Double ?? 0) != 0 { text = "<em>\(text)</em>" }
                if traits.contains(.fixedPitchFontMask) { text = "<code>\(text)</code>" }
                if font.pointSize >= 19 { text = "<span style=\"font-size:\(Int(font.pointSize))px\">\(text)</span>" }
            }
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 { text = "<u>\(text)</u>" }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "<s>\(text)</s>" }
            if let raw = attrs[.link] {
                let value = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                if let scheme = URL(string: value)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    text = "<a href=\"\(escape(value))\">\(text)</a>"
                }
            }
            output += text
        }
        return output
    }
    public static func document(title: String, content: NSAttributedString) -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(escape(title))</title>
        <style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;max-width:760px;margin:48px auto;padding:0 24px;color:#202124;background:#fff}img{vertical-align:middle}a{color:#485fd7}</style></head>
        <body>\(fragment(content))</body></html>
        """
    }
}
