import AppKit

public enum ClipboardImporter {
    public static func html(_ html: String) throws -> NSAttributedString {
        let prepared = preservingHeadings(in: html)
        let parsed = try NSAttributedString(data: Data(prepared.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ], documentAttributes: nil)
        return portableLists(parsed)
    }

    /// Keep heading semantics even when the HTML reader's default h2/h3 point sizes are smaller
    /// than the app's body font. xmlString's initializer preserves Unicode in HTML fragments.
    private static func preservingHeadings(in html: String) -> String {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let headings = try? document.nodes(forXPath: "//h1 | //h2 | //h3 | //h4 | //h5 | //h6"), !headings.isEmpty else { return html }
        for case let heading as XMLElement in headings {
            let size = heading.name?.lowercased() == "h1" ? 25 : 19
            let descendants = (try? heading.nodes(forXPath: ".//span | .//strong | .//em | .//a | .//b | .//i")) ?? []
            for case let element as XMLElement in [heading] + descendants {
                let styles = element.attribute(forName: "style")?.stringValue ?? ""
                element.removeAttribute(forName: "style")
                // AppKit's HTML reader maps CSS px directly to NSFont points; CSS pt is scaled.
                element.addAttribute(XMLNode.attribute(withName: "style", stringValue: styles + ";font-size:\(size)px !important;font-weight:bold !important;") as! XMLNode)
            }
        }
        return document.rootElement()?.xmlString ?? html
    }

    /// Materialize list markers before inserting text. Native HTML import emits numbered markers
    /// as tab + number + tab (without a period), while RTFD can otherwise lose generated markers.
    public static func portableLists(_ input: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: input)
        let string = input.string as NSString
        var offset = 0
        var counters: [ObjectIdentifier: Int] = [:]
        var replacements: [(NSRange, NSAttributedString)] = []
        while offset < string.length {
            let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
            defer { offset = range.location + range.length }
            guard let paragraph = input.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle,
                  let list = paragraph.textLists.last else { continue }
            let id = ObjectIdentifier(list)
            let number = (counters[id] ?? max(1, list.startingItemNumber) - 1) + 1; counters[id] = number
            let marker = list.marker(forItemNumber: number)
            let body = NSMutableAttributedString(attributedString: input.attributedSubstring(from: range))
            let nativePrefix = "\t\(marker)\t"
            if body.string.hasPrefix(nativePrefix) {
                body.deleteCharacters(in: NSRange(location: 0, length: (nativePrefix as NSString).length))
            } else {
                // Only remove the expected marker, so a year or a user-written number in the
                // item's actual content is preserved.
                let escaped = NSRegularExpression.escapedPattern(for: marker)
                let expression = try! NSRegularExpression(pattern: "^[ \\t]*\(escaped)[.)]?[ \\t]+")
                if let match = expression.firstMatch(in: body.string, range: NSRange(location: 0, length: body.length)) {
                    body.deleteCharacters(in: match.range)
                }
            }
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.textLists = []; style.firstLineHeadIndent = 0; style.headIndent = 0
            body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
            var attributes = body.length > 0 ? body.attributes(at: 0, effectiveRange: nil) : input.attributes(at: offset, effectiveRange: nil)
            attributes[.paragraphStyle] = style; attributes.removeValue(forKey: .link); attributes.removeValue(forKey: .attachment)
            let punctuation = list.isOrdered && !marker.hasSuffix(".") && !marker.hasSuffix(")") ? "." : ""
            let prefix = String(repeating: "  ", count: max(0, paragraph.textLists.count - 1)) + marker + punctuation + " "
            body.insert(NSAttributedString(string: prefix, attributes: attributes), at: 0)
            replacements.append((range, body))
        }
        for (range, body) in replacements.reversed() { result.replaceCharacters(in: range, with: body) }
        return result
    }
}
