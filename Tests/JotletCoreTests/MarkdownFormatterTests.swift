import XCTest
import AppKit
@testable import JotletCore

final class MarkdownFormatterTests: XCTestCase {
    func testNestedQuotesAndLiteralCheckboxCodeRemainDistinct() async throws {
        try await MainActor.run {
            let quote = try MarkdownFormatter.document("> > 嵌套引用\n\n正文")
            XCTAssertEqual(quote.string, "› › 嵌套引用\n正文")
            XCTAssertEqual(try MarkdownFormatter.document(MarkdownExporter.document(quote)).string, quote.string)
            let code = try MarkdownFormatter.document("```\n☐ literal\n```")
            XCTAssertNil(TextList.parse(code))
            XCTAssertEqual((code.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, 0)
            XCTAssertTrue(MarkdownExporter.document(code).contains("`☐ literal`"))
            let indented = try MarkdownFormatter.document("    - [] literal")
            XCTAssertEqual(indented.string, "- [] literal\n")
            XCTAssertNil(TextList.parse(indented))
        }
    }

    func testShorthandTasksAndEmptyItemsWithoutChangingCodeExamples() async throws {
        try await MainActor.run {
            let source = "- [] 写 **初稿**\n- [x] 看结果\n  - [] 子任务\n- []\n\n```text\n- [] literal\n```"
            let text = try MarkdownFormatter.document(source)
            XCTAssertTrue(text.string.hasPrefix("☐ 写 初稿\n☑ 看结果\n  ☐ 子任务\n☐ "))
            XCTAssertTrue(text.string.contains("- [] literal"))
            let read = try NSAttributedString(data: NoteStore.encodeContent(text), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            XCTAssertEqual(read.string, text.string)
            let paragraph = read.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
            XCTAssertGreaterThan(paragraph.headIndent, paragraph.firstLineHeadIndent + 10)
            XCTAssertTrue(MarkdownExporter.document(read).contains("- [ ] 写 **初稿**"))
        }
    }

    func testQuotesPreserveTheirStructureAcrossStorageAndMarkdownCopy() async throws {
        try await MainActor.run {
            let original = try MarkdownFormatter.document("> 先把问题写清楚\n> 再试一个小步骤\n\n正文")
            XCTAssertEqual(original.string, "› 先把问题写清楚\n› 再试一个小步骤\n正文")
            let read = try NSAttributedString(data: NoteStore.encodeContent(original), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            let copied = MarkdownExporter.document(read)
            XCTAssertTrue(copied.hasPrefix("> 先把问题写清楚\n> 再试一个小步骤"))
            XCTAssertEqual(try MarkdownFormatter.document(copied).string, original.string)
        }
    }

    func testNestedTasksRetainDepthWhenExportedUnderNumberedLists() async throws {
        try await MainActor.run {
            let text = try MarkdownFormatter.document("1. 准备\n   - [] 子任务\n2. 完成")
            let copied = MarkdownExporter.document(text)
            XCTAssertTrue(copied.contains("    - [ ] 子任务"))
            XCTAssertEqual(try MarkdownFormatter.document(copied).string, text.string)
        }
    }

    func testMarkdownKeepsHeadingsListsTasksAndInlineFormattingAfterStorage() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let source = "# 本周\n\n## 安排\n- [ ] 写 **初稿**\n- [x] 看 *结果*\n\n3. 第三项\n4. 第四项\n\n[参考](https://example.com)\n"
            let text = try MarkdownFormatter.document(source)
            XCTAssertEqual(text.string, "本周\n安排\n☐ 写 初稿\n☑ 看 结果\n3. 第三项\n4. 第四项\n参考\n")
            XCTAssertEqual((text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 25)
            let title = (text.string as NSString).range(of: "安排")
            XCTAssertEqual((text.attribute(.font, at: title.location, effectiveRange: nil) as! NSFont).pointSize, 19)
            let bold = (text.string as NSString).range(of: "初稿")
            XCTAssertTrue(NSFontManager.shared.traits(of: text.attribute(.font, at: bold.location, effectiveRange: nil) as! NSFont).contains(.boldFontMask))
            let link = (text.string as NSString).range(of: "参考")
            XCTAssertEqual(text.attribute(.link, at: link.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
            let reopened = try NSAttributedString(data: NoteStore.encodeContent(text), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            XCTAssertEqual(reopened.string, text.string)
            XCTAssertEqual((reopened.attribute(.font, at: title.location, effectiveRange: nil) as! NSFont).pointSize, 19)
        }
    }

    func testPlainClipboardTextIsNotReformatted() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            XCTAssertNil(try MarkdownFormatter.documentIfMarkdown("中文与 English\n\nemoji 📝\n最后一行"))
            XCTAssertNil(try MarkdownFormatter.documentIfMarkdown("2 * 3 = 6\n文件名 foo_bar_baz"))
        }
    }

    func testNestedListsAndLiteralNumbersStayReadable() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let text = try MarkdownFormatter.document("7. 2026\\. 年度计划\n   - 中文 📝\n8. 下一项")
            XCTAssertEqual(text.string, "7. 2026. 年度计划\n  • 中文 📝\n8. 下一项")
        }
    }

    func testSoftBreaksAndCodePreserveText() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let text = try MarkdownFormatter.document("**正文**\n下一行\n\n```swift\nlet a = 1\nlet b = 2\n```")
            XCTAssertTrue(text.string.contains("正文\n下一行"))
            XCTAssertTrue(text.string.contains("let a = 1\nlet b = 2\n"))
            let range = (text.string as NSString).range(of: "let a")
            XCTAssertTrue(NSFontManager.shared.traits(of: text.attribute(.font, at: range.location, effectiveRange: nil) as! NSFont).contains(.fixedPitchFontMask))
        }
    }

    func testEmptyParentListItemKeepsItsNumber() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let text = try MarkdownFormatter.document("7. 2026. 子项目")
            XCTAssertEqual(text.string, "7. \n  2026. 子项目")
        }
    }

    func testEscapesAndExistingHeadingSizeArePreservedInline() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19)]
            let escaped = try MarkdownFormatter.inline("\\*普通字符\\*", attributes: attrs)
            XCTAssertEqual(escaped.string, "*普通字符*")
            let formatted = try MarkdownFormatter.inline("**加粗 📝**", attributes: attrs)
            let font = formatted.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            XCTAssertEqual(font.pointSize, 19)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        }
    }

    func testUnsupportedImagesStayAsSourceWithoutLosingTheURL() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let source = "# 图片\n![说明](https://example.com/photo.png)"
            XCTAssertEqual(try MarkdownFormatter.document(source).string, source)
            XCTAssertNil(try MarkdownFormatter.documentIfMarkdown(source))
        }
    }
}
