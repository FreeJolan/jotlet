import AppKit

public struct WindowFrame: Codable, Equatable {
    public var x, y, width, height: Double
    public init(_ rect: NSRect) {
        x = rect.origin.x; y = rect.origin.y
        width = rect.width; height = rect.height
    }
    public var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

public struct Note: Codable, Identifiable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var modifiedAt: Date
    public var preview: String
    public var isPinned: Bool
    public var isVisible: Bool
    public var isCollapsed: Bool?
    public var deletedAt: Date?
    public var frame: WindowFrame?
    public init(id: UUID = UUID()) {
        self.id = id; createdAt = Date(); modifiedAt = createdAt
        preview = ""; isPinned = false; isVisible = true; isCollapsed = false
    }
    public var title: String {
        let first = preview.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let clean = first.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "新便签" : String(clean.prefix(60))
    }
    public var isDeleted: Bool { deletedAt != nil }
}

public struct LibraryIndex: Codable {
    public var version = 1
    public var notes: [Note]
    public init(notes: [Note]) { self.notes = notes }
}

public enum JotletError: LocalizedError {
    case unsupportedVersion, invalidBackup, missingContent(String), corruptLibrary
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "这份数据来自更新版本的 Jotlet，请更新应用后再打开。"
        case .invalidBackup: return "备份不完整或格式不正确，现有便签未被更改。"
        case .missingContent(let title): return "无法读取便签“\(title)”的内容。请从备份恢复，避免覆盖原始内容。"
        case .corruptLibrary: return "便签列表无法读取。请保留数据目录，并从备份恢复。"
        }
    }
}
