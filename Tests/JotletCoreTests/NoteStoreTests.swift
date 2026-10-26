import XCTest
import AppKit
@testable import JotletCore

final class NoteStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JotletTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func sample() -> NSAttributedString {
        _ = NSApplication.shared
        let content = NSMutableAttributedString(string: "标题 & <链接>\n☐ 一项任务\n中文 emoji 📝\n", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
        content.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24), range: NSRange(location: 0, length: 2))
        let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        let wrapper = FileWrapper(regularFileWithContents: image.tiffRepresentation!)
        wrapper.preferredFilename = "sample.tiff"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        content.append(NSAttributedString(attachment: attachment))
        return content
    }
    func testRichTextAndImageSurviveSaveAndRestart() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root), source = sample()
            let note = try store.create(content: source)
            try store.update(note.id) { $0.isPinned = true; $0.frame = WindowFrame(NSRect(x: 12, y: 30, width: 440, height: 500)) }
            let reopened = try NoteStore(root: root), loaded = try reopened.content(note.id)
            XCTAssertEqual(loaded.string, source.string)
            XCTAssertEqual(reopened.note(note.id)?.isPinned, true)
            XCTAssertEqual(reopened.note(note.id)?.frame?.width, 440)
            let font = loaded.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            let attachment = loaded.attribute(.attachment, at: loaded.length - 1, effectiveRange: nil) as? NSTextAttachment
            XCTAssertNotNil(attachment?.fileWrapper?.regularFileContents)
            XCTAssertNotNil(attachment.flatMap(HTMLExporter.imageData))
        }
    }
    func testBackupRestorePreservesImagesAndExistingNotes() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root), source = sample()
            let original = try store.create(content: source)
            let archive = root.appendingPathComponent("complete.jotletbackup")
            try store.exportBackup(to: archive)
            try store.save(original.id, content: NSAttributedString(string: "备份之后的新内容"))
            XCTAssertEqual(try store.importBackup(from: archive), 1)
            XCTAssertEqual(store.notes.count, 2)
            XCTAssertEqual(try store.content(original.id).string, "备份之后的新内容")
            let restored = store.notes.first { $0.id != original.id }!
            XCTAssertEqual(try store.content(restored.id).string, source.string)
            XCTAssertFalse(restored.isVisible)
        }
    }
    func testInvalidBackupDoesNotChangeLibrary() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root)
            let note = try store.create(content: NSAttributedString(string: "现有内容"))
            let archive = root.appendingPathComponent("broken.jotletbackup")
            try store.exportBackup(to: archive)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as! [String: Any]
            json["documents"] = [String: String]()
            try JSONSerialization.data(withJSONObject: json).write(to: archive)
            XCTAssertThrowsError(try store.importBackup(from: archive))
            XCTAssertEqual(store.notes.map(\.id), [note.id])
            XCTAssertEqual(try store.content(note.id).string, "现有内容")
        }
    }
    func testTrashAndRestoreKeepContent() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root)
            let note = try store.create(content: sample())
            try store.trash(note.id)
            XCTAssertTrue(store.note(note.id)!.isDeleted); XCTAssertFalse(store.note(note.id)!.isVisible)
            let text = try store.content(note.id).string
            try store.restore(note.id)
            XCTAssertFalse(store.note(note.id)!.isDeleted)
            XCTAssertEqual(try store.content(note.id).string, text)
        }
    }
    func testHTMLExportIsStandaloneAndEscapesContent() async throws {
        await MainActor.run {
            let html = HTMLExporter.document(title: "<script>", content: sample())
            XCTAssertTrue(html.contains("&lt;script&gt;"))
            XCTAssertFalse(html.contains("<script>"))
            XCTAssertTrue(html.contains("data:image/png;base64,"))
            XCTAssertTrue(html.contains("<strong>"))
            XCTAssertTrue(html.contains("中文 emoji 📝"))
        }
    }
    func testSaveFailureDoesNotPretendMetadataWasSaved() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root)
            let note = try store.create(content: NSAttributedString(string: "旧内容"))
            let folder = root.appendingPathComponent("Notes")
            try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Notes-original"))
            try Data("not a directory".utf8).write(to: folder)
            XCTAssertThrowsError(try store.save(note.id, content: NSAttributedString(string: "新内容")))
            XCTAssertEqual(store.note(note.id)?.preview, "旧内容")
        }
    }
    func testEmptyNoteCanBeSavedAndReopened() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root), note = try store.create()
            XCTAssertEqual(try store.content(note.id).string, "")
        }
    }
    func testCorruptIndexRecoversRecentOrphanContent() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root)
            let first = try store.create(content: NSAttributedString(string: "第一张"))
            let second = try store.create(content: NSAttributedString(string: "最新一张"))
            try Data("broken index".utf8).write(to: root.appendingPathComponent("index.json"))
            let recovered = try NoteStore(root: root)
            XCTAssertEqual(Set(recovered.notes.map(\.id)), Set([first.id, second.id]))
            XCTAssertEqual(try recovered.content(second.id).string, "最新一张")
            XCTAssertNotNil(recovered.recoveryMessage)
        }
    }
    func testEmptyTrashCreatesRestorableBackup() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root), note = try store.create(content: sample())
            try store.trash(note.id); try store.emptyTrash()
            XCTAssertTrue(store.notes.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.contentURL(note.id).path))
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try store.importBackup(from: files[0]), 1)
            XCTAssertTrue(try store.content(store.notes[0].id).containsAttachments)
        }
    }
    func testUnrecoverableIndexStillAllowsBackupImport() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root), note = try store.create(content: sample())
            let archive = root.appendingPathComponent("saved.jotletbackup")
            try store.exportBackup(to: archive)
            try FileManager.default.removeItem(at: store.contentURL(note.id))
            try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))
            let recovered = try NoteStore(root: root)
            XCTAssertNotNil(recovered.recoveryMessage); XCTAssertTrue(recovered.notes.isEmpty)
            XCTAssertEqual(try recovered.importBackup(from: archive), 1)
            XCTAssertTrue(try recovered.content(recovered.notes[0].id).containsAttachments)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertTrue(files.contains { $0.hasPrefix("index-damaged-") })
        }
    }
    func testInterruptedSaveRepairsSearchPreviewFromDocument() async throws {
        try await MainActor.run {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try NoteStore(root: root), note = try store.create(content: NSAttributedString(string: "旧正文"))
            try NoteStore.encodeContent(NSAttributedString(string: "最新正文，包含新搜索词")).write(to: store.contentURL(note.id), options: .atomic)
            let reopened = try NoteStore(root: root)
            XCTAssertEqual(reopened.note(note.id)?.preview, "最新正文，包含新搜索词")
            XCTAssertEqual(try reopened.content(note.id).string, "最新正文，包含新搜索词")
        }
    }
}
