import AppKit

public enum RichTextStyles {
    /// Some editors ignore Cocoa's synthetic obliqueness attribute on paste. Encode that
    /// emphasis as a standard italic font in clipboard formats, keeping the stored text intact.
    public static func clipboardContent(_ content: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
            guard (attributes[.obliqueness] as? Double ?? 0) != 0,
                  let font = attributes[.font] as? NSFont else { return }
            let oldTraits = NSFontManager.shared.traits(of: font)
            let base = oldTraits.contains(.fixedPitchFontMask) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : NSFont.systemFont(ofSize: font.pointSize)
            let traits = oldTraits.intersection(.boldFontMask).union(.italicFontMask)
            result.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: traits), range: range)
            result.removeAttribute(.obliqueness, range: range)
        }
        return result
    }

    /// AppKit substitutes unsupported Chinese glyphs with PingFang, which has no italic face.
    /// A synthetic slant keeps the visible emphasis when that substitution would lose it.
    public static func preservingItalic(_ content: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let font = value as? NSFont, NSFontManager.shared.traits(of: font).contains(.italicFontMask) else { return }
            let text = content.attributedSubstring(from: range).string
            guard text.unicodeScalars.contains(where: { !font.coveredCharacterSet.contains($0) }) else { return }
            result.addAttribute(.font, value: NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask), range: range)
            result.addAttribute(.obliqueness, value: 0.18, range: range)
        }
        return result
    }
}
