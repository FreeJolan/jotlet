import XCTest
import AppKit
@testable import JotletCore

final class NoteCompatibilityTests: XCTestCase {
    func testOlderNoteWithoutCollapseFieldLoadsNormally() throws {
        var note = Note()
        note.preview = "已有便签"
        note.frame = WindowFrame(NSRect(x: 40, y: 80, width: 430, height: 510))
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        old.removeValue(forKey: "isCollapsed")
        let restored = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertFalse(restored.isCollapsed ?? false)
        XCTAssertEqual(restored.preview, note.preview)
        XCTAssertEqual(restored.frame, note.frame)
    }
    func testCollapsedNotePreservesExpandedGeometryAcrossRestart() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("JotletCollapse-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root)
            let note = try store.create(content: NSAttributedString(string: "折叠后的内容"))
            let frame = WindowFrame(NSRect(x: 20, y: 30, width: 440, height: 500))
            try store.update(note.id) { $0.isCollapsed = true; $0.frame = frame; $0.isPinned = true }
            let reopened = try NoteStore(root: root)
            XCTAssertEqual(reopened.note(note.id)?.isCollapsed, true)
            XCTAssertEqual(reopened.note(note.id)?.frame, frame)
            XCTAssertEqual(reopened.note(note.id)?.isPinned, true)
            XCTAssertEqual(try reopened.content(note.id).string, "折叠后的内容")
        }
    }
}
