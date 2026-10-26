import XCTest
import AppKit
@testable import JotletCore

final class ClipboardExportTests: XCTestCase {
    func testHTMLNestedListsAreInsideTheirParentItem() async throws {
        try await MainActor.run {
            let content = try MarkdownFormatter.document("- 父项\n  - 子项\n- 第二项")
            let html = HTMLExporter.fragment(content)
            XCTAssertTrue(html.contains("<li>父项<ul"))
            XCTAssertTrue(html.contains("子项</li></ul></li><li>第二项"))
            let read = try ClipboardImporter.html(html)
            XCTAssertTrue(read.string.contains("父项"))
            XCTAssertTrue(read.string.contains("子项"))
        }
    }

    func testHTMLCopyIncludesTaskStateQuotesCodeAndStrikethrough() async throws {
        try await MainActor.run {
            let text = try MarkdownFormatter.document("- [] 写 **初稿**\n- [x] 完成\n\n> 参考意见\n\n`code` 和 ~~删除~~")
            let html = HTMLExporter.fragment(text)
            XCTAssertTrue(html.contains("☐ <span"))
            XCTAssertTrue(html.contains("☑ <span style=\"color:#888;text-decoration:line-through;\""))
            XCTAssertTrue(html.contains("<blockquote"))
            XCTAssertTrue(html.contains("<code>code</code>"))
            XCTAssertTrue(html.contains("<s>删除</s>"))
            let copied = try ClipboardImporter.html(html)
            XCTAssertTrue(copied.string.contains("☐ 写 初稿"))
            XCTAssertTrue(copied.string.contains("☑ 完成"))
            XCTAssertFalse(copied.string.contains("• ☑"))
        }
    }

    func testHTMLCopyCarriesHeadingAndListSemanticsWithoutDuplicateMarkers() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let content = try MarkdownFormatter.document("# 本周\n\n- 项目一\n- 项目二\n\n3. 第三项\n4. 第四项\n\n[参考](https://example.com)")
            let html = HTMLExporter.fragment(content)
            XCTAssertTrue(html.contains("<h1"))
            XCTAssertTrue(html.contains("<ul"))
            XCTAssertTrue(html.contains("<ol start=\"3\""))
            XCTAssertTrue(html.contains("href=\"https://example.com\""))
            XCTAssertFalse(html.contains("• 项目"))
            let read = try ClipboardImporter.html(html)
            let lines = read.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            XCTAssertEqual(lines, ["本周", "• 项目一", "• 项目二", "3. 第三项", "4. 第四项", "参考"])
            XCTAssertEqual((read.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 25)
        }
    }

    func testCopyAsMarkdownCanBeRenderedAgainWithFormattingAndLiteralPunctuation() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let original = try MarkdownFormatter.document("# 本周\n\n- [ ] 写 **初稿**\n- [x] 看 *结果*\n\n3. 2026\\. 年度计划\n\n[参考](https://example.com)")
            let copied = MarkdownExporter.document(original)
            XCTAssertTrue(copied.contains("# 本周"))
            XCTAssertTrue(copied.contains("- [ ] 写 **初稿**"))
            XCTAssertTrue(copied.contains("- [x] 看 *结果*"))
            let roundTrip = try MarkdownFormatter.document(copied)
            XCTAssertEqual(roundTrip.string, original.string)
            let linkRange = (roundTrip.string as NSString).range(of: "参考")
            XCTAssertEqual(roundTrip.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        }
    }

    func testMarkdownEscapesLiteralSyntaxAndBackticks() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let text = NSMutableAttributedString(string: "literal **stars** [brackets] # hash 📝\n", attributes: MarkdownFormatter.bodyAttributes)
            text.append(NSAttributedString(string: "a`b", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)]))
            let copied = MarkdownExporter.document(text)
            XCTAssertTrue(copied.contains("\\*\\*stars\\*\\*"))
            XCTAssertTrue(copied.contains("``a`b``"))
            XCTAssertEqual(try MarkdownFormatter.document(copied).string, text.string)
        }
    }

    func testChineseItalicAndStyledWhitespaceSurviveCopyAndStorage() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let source = NSMutableAttributedString(attributedString: RichTextStyles.preservingItalic(try MarkdownFormatter.document("*中文斜体*")))
            source.append(NSAttributedString(string: " 加粗 ", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)]))
            source.append(NSAttributedString(string: " a ` b ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)]))
            let reopened = try NSAttributedString(data: NoteStore.encodeContent(source), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            XCTAssertGreaterThan(reopened.attribute(.obliqueness, at: 0, effectiveRange: nil) as? Double ?? 0, 0)
            let copied = MarkdownExporter.document(reopened)
            XCTAssertTrue(copied.contains("*中文斜体*"))
            XCTAssertTrue(copied.contains(" **加粗** "))
            XCTAssertTrue(HTMLExporter.fragment(reopened).contains("<em>"))
            XCTAssertEqual(try MarkdownFormatter.document(copied).string, source.string)
            let portable = RichTextStyles.clipboardContent(reopened)
            let rtf = try portable.data(from: NSRange(location: 0, length: portable.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let read = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            XCTAssertEqual(read.string, source.string)
            XCTAssertTrue(NSFontManager.shared.traits(of: read.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.italicFontMask))
        }
    }
}
