import AppKit

/// All operations are run on the application's main thread. Content and indexes use atomic writes.
public final class NoteStore {
    public let root: URL
    public private(set) var notes: [Note] = []
    public private(set) var recoveryMessage: String?
    public var onChange: (() -> Void)?
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var dirtySinceBackup = false

    public init(root: URL) throws {
        self.root = root
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try fm.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("index.json")
        if fm.fileExists(atPath: indexURL.path) {
            do { notes = try readIndex(indexURL).notes }
            catch JotletError.unsupportedVersion { throw JotletError.unsupportedVersion }
            catch {
                if let damaged = try? Data(contentsOf: indexURL) {
                    try damaged.write(to: root.appendingPathComponent("index-damaged-\(UUID().uuidString).json"), options: .atomic)
                }
                let previous = root.appendingPathComponent("index.previous.json")
                notes = ((try? readIndex(previous))?.notes ?? []).filter { fm.fileExists(atPath: contentURL($0.id).path) }
                let existing = Set(notes.map(\.id))
                let files = try fm.contentsOfDirectory(at: root.appendingPathComponent("Notes"), includingPropertiesForKeys: [.contentModificationDateKey])
                for file in files where file.pathExtension == "rtfddata" {
                    guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !existing.contains(id),
                          let data = try? Data(contentsOf: file),
                          let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) else { continue }
                    var note = Note(id: id); note.preview = Self.preview(text); note.isVisible = false
                    note.modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    notes.append(note)
                }
                recoveryMessage = notes.isEmpty
                    ? "数据列表无法恢复，损坏的列表和正文已保留。请从列表右上角菜单选择“从备份恢复”，或打开自动备份文件夹查找备份。"
                    : "上次保存的列表无法读取，已从上一份列表和本地正文恢复便签。请导出一份完整备份。"
            }
        }
        // A crash can happen between the atomic content write and the index write.
        // Treat the stored document as authoritative when rebuilding previews and search text.
        var needsReindex = false
        for position in notes.indices {
            if let body = try? content(notes[position].id) {
                let actual = Self.preview(body)
                if actual != notes[position].preview {
                    notes[position].preview = actual
                    notes[position].modifiedAt = (try? contentURL(notes[position].id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    needsReindex = true
                }
            }
        }
        if needsReindex { try commit(notes) }
    }

    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["JOTLET_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jotlet", isDirectory: true)
    }

    public func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }
    public func contentURL(_ id: UUID) -> URL {
        root.appendingPathComponent("Notes").appendingPathComponent(id.uuidString + ".rtfddata")
    }
    private func readIndex(_ url: URL) throws -> LibraryIndex {
        let index = try decoder.decode(LibraryIndex.self, from: Data(contentsOf: url))
        guard index.version == 1 else { throw JotletError.unsupportedVersion }
        guard Set(index.notes.map(\.id)).count == index.notes.count else { throw JotletError.corruptLibrary }
        return index
    }

    public func content(_ id: UUID) throws -> NSAttributedString {
        guard let note = note(id) else { throw JotletError.missingContent("未知便签") }
        do {
            let data = try Data(contentsOf: contentURL(id))
            return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        } catch { throw JotletError.missingContent(note.title) }
    }

    @discardableResult
    public func create(content: NSAttributedString = NSAttributedString(string: "")) throws -> Note {
        var note = Note()
        note.preview = Self.preview(content)
        let data = try Self.encodeContent(content)
        try data.write(to: contentURL(note.id), options: .atomic)
        var next = notes; next.append(note)
        try commit(next)
        return note
    }

    public static func encodeContent(_ content: NSAttributedString) throws -> Data {
        // Apple's flattened RTFD representation includes the original attachment bytes.
        try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }
    public static func preview(_ content: NSAttributedString) -> String {
        content.string.replacingOccurrences(of: "\u{FFFC}", with: "[图片]")
    }

    public func save(_ id: UUID, content: NSAttributedString) throws {
        guard let position = notes.firstIndex(where: { $0.id == id }) else { throw JotletError.missingContent("未知便签") }
        let data = try Self.encodeContent(content)
        try data.write(to: contentURL(id), options: .atomic)
        var next = notes
        next[position].preview = Self.preview(content)
        next[position].modifiedAt = Date()
        try commit(next)
    }

    public func update(_ id: UUID, _ change: (inout Note) -> Void) throws {
        guard let position = notes.firstIndex(where: { $0.id == id }) else { return }
        var next = notes; change(&next[position]); try commit(next)
    }
    public func trash(_ id: UUID) throws {
        try update(id) { $0.deletedAt = Date(); $0.isVisible = false }
    }
    public func restore(_ id: UUID) throws {
        try update(id) { $0.deletedAt = nil; $0.isVisible = false }
    }
    public func emptyTrash() throws {
        let deleted = notes.filter(\.isDeleted)
        guard !deleted.isEmpty else { return }
        try automaticBackup(force: true)
        try commit(notes.filter { !$0.isDeleted })
        for note in deleted { try fm.removeItem(at: contentURL(note.id)) }
    }

    private func commit(_ next: [Note]) throws {
        let data = try encoder.encode(LibraryIndex(notes: next))
        let url = root.appendingPathComponent("index.json")
        if fm.fileExists(atPath: url.path), recoveryMessage == nil {
            try Data(contentsOf: url).write(to: root.appendingPathComponent("index.previous.json"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        notes = next; dirtySinceBackup = true; onChange?()
    }

    private struct Archive: Codable {
        var format = "Jotlet Backup"
        var version = 1
        var createdAt = Date()
        var notes: [Note]
        var documents: [String: Data]
    }
    public func exportBackup(to url: URL) throws {
        var documents: [String: Data] = [:]
        for note in notes {
            let data = try Data(contentsOf: contentURL(note.id))
            _ = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            documents[note.id.uuidString] = data
        }
        let data = try encoder.encode(Archive(notes: notes, documents: documents))
        try data.write(to: url, options: .atomic)
    }
    /// Restores as new notes, preserving the current library and validating the entire archive first.
    @discardableResult
    public func importBackup(from url: URL) throws -> Int {
        let archive: Archive
        do { archive = try decoder.decode(Archive.self, from: Data(contentsOf: url)) }
        catch { throw JotletError.invalidBackup }
        guard archive.format == "Jotlet Backup", archive.version == 1,
              Set(archive.notes.map(\.id)).count == archive.notes.count,
              archive.documents.count == archive.notes.count else { throw JotletError.invalidBackup }
        var additions: [(Note, Data)] = []
        for old in archive.notes {
            guard let data = archive.documents[old.id.uuidString],
                  let content = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) else { throw JotletError.invalidBackup }
            var restored = old
            restored.id = UUID(); restored.isVisible = false; restored.frame = nil
            restored.preview = Self.preview(content)
            additions.append((restored, data))
        }
        var written: [URL] = []
        do {
            for (note, data) in additions {
                let path = contentURL(note.id); try data.write(to: path, options: .atomic); written.append(path)
            }
            try commit(notes + additions.map(\.0))
        } catch {
            for path in written { try? fm.removeItem(at: path) }
            throw error
        }
        return additions.count
    }

    public func automaticBackup(force: Bool = false) throws {
        guard (force || dirtySinceBackup), !notes.isEmpty else { return }
        let directory = root.appendingPathComponent("Backups")
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = directory.appendingPathComponent("Jotlet-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).jotletbackup")
        try exportBackup(to: url); dirtySinceBackup = false
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "jotletbackup" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(20) { try fm.removeItem(at: old) }
    }
}
