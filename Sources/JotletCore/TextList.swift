import AppKit

/// Portable markers stay in the document, while the editor can draw richer controls over them.
/// No attachment or custom RTF attribute is needed to save or copy a task.
public struct TextList {
    public let prefixRange: NSRange
    public let markerRange: NSRange
    public let indentation: String
    public let marker: String
    public var isTask: Bool { marker == "☐ " || marker == "☑ " }
    public var isCompleted: Bool { marker == "☑ " }
    public var isQuote: Bool { marker.hasPrefix("› ") }

    public static func parse(_ line: NSAttributedString) -> TextList? {
        if line.length > 0, let font = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
           NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) { return nil }
        return parse(line.string)
    }

    public static func parse(_ line: String) -> TextList? {
        let text = line as NSString
        let expression = try! NSRegularExpression(pattern: "^( *)([•☐☑] |[0-9]+\\. |(?:› )+)")
        guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return nil }
        return TextList(prefixRange: match.range, markerRange: match.range(at: 2),
                        indentation: text.substring(with: match.range(at: 1)), marker: text.substring(with: match.range(at: 2)))
    }

    /// Hanging indents keep wrapped task text aligned with its first line.
    public static func paragraphStyle(for line: NSAttributedString) -> NSParagraphStyle {
        let original = line.length > 0 ? line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        let style = (original?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        guard style.textLists.isEmpty, style.textBlocks.isEmpty else { return style }
        style.lineSpacing = 5
        style.paragraphSpacing = 6
        style.paragraphSpacingBefore = 0
        style.firstLineHeadIndent = 0; style.headIndent = 0
        if let list = parse(line) {
            let prefix = line.attributedSubstring(from: list.prefixRange)
            style.firstLineHeadIndent = CGFloat(list.indentation.count / 2) * 16
            style.headIndent = style.firstLineHeadIndent + ceil(prefix.size().width)
            if list.isTask { style.paragraphSpacing = 8 }
            if list.isQuote { style.paragraphSpacingBefore = 4; style.paragraphSpacing = 8 }
        }
        return style
    }
}
