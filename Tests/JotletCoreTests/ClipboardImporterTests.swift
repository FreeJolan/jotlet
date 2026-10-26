import XCTest
import AppKit
@testable import JotletCore

final class ClipboardImporterTests: XCTestCase {
    func testLarkNumberedHeadingsKeepOneNumberAndHeadingStyle() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let path = Bundle.module.url(forResource: "LarkNumberedHeadings", withExtension: "html", subdirectory: "Fixtures")!
            let content = try ClipboardImporter.html(String(contentsOf: path, encoding: .utf8))
            let numbered = content.string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.range(of: "^[0-9]+\\.", options: .regularExpression) != nil }
            XCTAssertEqual(numbered, ["1. 示例内容", "2. 示例内容", "3. 示例内容", "1. 示例内容"])
            XCTAssertFalse(content.string.contains("\t1\t"))
            let ns = content.string as NSString
            var position = 0, headings = 0
            while position < ns.length {
                let range = ns.paragraphRange(for: NSRange(location: position, length: 0))
                if let font = content.attribute(.font, at: position, effectiveRange: nil) as? NSFont, font.pointSize >= 19 {
                    headings += 1
                    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
                }
                position = NSMaxRange(range)
            }
            XCTAssertEqual(headings, 6)
            let reopened = try NSAttributedString(data: NoteStore.encodeContent(content), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            XCTAssertEqual(reopened.string, content.string)
        }
    }
    func testOrderedListStartAndLiteralNumbersArePreserved() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let content = try ClipboardImporter.html("<ol start='7'><li>2026. 年度计划</li><li>下一项</li></ol>")
            XCTAssertEqual(content.string.trimmingCharacters(in: .whitespacesAndNewlines), "7. 2026. 年度计划\n8. 下一项")
        }
    }
    func testNestedListsAreNotNumberedTwice() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let content = try ClipboardImporter.html("<ol><li>第一层<ol><li>第二层</li></ol></li><li>下一项</li></ol>")
            XCTAssertFalse(content.string.contains("\t1\t"))
            XCTAssertTrue(content.string.contains("1. 第一层"))
            XCTAssertTrue(content.string.contains("  1. 第二层"))
            XCTAssertTrue(content.string.contains("2. 下一项"))
        }
    }
    func testHeadingWithExplicitChildSizeKeepsHeadingSemantics() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let content = try ClipboardImporter.html("<h3><span style='font-size:14px'>中文标题 📝</span></h3><p>正文</p>")
            let font = content.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            XCTAssertEqual(font.pointSize, 19, accuracy: 0.1)
            XCTAssertTrue(content.string.contains("中文标题 📝"))
        }
    }
}
