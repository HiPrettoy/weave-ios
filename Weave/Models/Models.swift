import Foundation

// MARK: - 采集来源

enum CaptureSource: String, Codable, CaseIterable, Identifiable {
    case text
    case voice
    case photo
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "文字"
        case .voice: return "语音"
        case .photo: return "拍照"
        case .manual: return "手记"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .voice: return "waveform"
        case .photo: return "camera"
        case .manual: return "square.and.pencil"
        }
    }
}

// MARK: - 关联类型

enum LinkKind: String, Codable {
    case semantic
    case tag
    case temporal

    var label: String {
        switch self {
        case .semantic: return "语义相近"
        case .tag: return "共同标签"
        case .temporal: return "同一时段"
        }
    }

    var symbol: String {
        switch self {
        case .semantic: return "sparkles"
        case .tag: return "tag"
        case .temporal: return "clock"
        }
    }
}

// MARK: - 笔记

struct Note: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
    var source: CaptureSource
    var summary: String
    var concepts: [String]
    var imageData: Data?
    var isFavorite: Bool
    /// 512 维本地向量，用于相似度计算；空数组表示还没算过
    var embedding: [Float]

    init(id: UUID = UUID(),
         title: String = "",
         content: String = "",
         tags: [String] = [],
         source: CaptureSource = .text,
         createdAt: Date = Date(),
         imageData: Data? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.source = source
        self.summary = ""
        self.concepts = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.imageData = imageData
        self.isFavorite = false
        self.embedding = []
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            switch source {
            case .photo: return "图片笔记"
            case .voice: return "语音笔记"
            default: return "无标题笔记"
            }
        }
        return trimmed.count > 22 ? String(trimmed.prefix(22)) + "…" : trimmed
    }

    var snippet: String {
        let flattened = content.replacingOccurrences(of: "\n", with: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }

    var indexingText: String {
        [title, content, tags.joined(separator: " "), concepts.joined(separator: " ")]
            .joined(separator: " ")
    }

    /// 分享、导出用的纯文本
    var plainText: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        parts.append(content)
        if !tags.isEmpty { parts.append(tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: "\n")
    }
}

// MARK: - 关联边

struct NoteLink: Identifiable, Codable, Hashable {
    /// 无序对的稳定键：小 UUID|大 UUID
    var id: String
    var a: UUID
    var b: UUID
    var score: Double
    var kind: LinkKind
    var createdAt: Date

    init(a: UUID, b: UUID, score: Double, kind: LinkKind, createdAt: Date = Date()) {
        self.a = a
        self.b = b
        self.score = score
        self.kind = kind
        self.createdAt = createdAt
        self.id = NoteLink.pairKey(a, b)
    }

    static func pairKey(_ x: UUID, _ y: UUID) -> String {
        let left = x.uuidString
        let right = y.uuidString
        return left < right ? "\(left)|\(right)" : "\(right)|\(left)"
    }

    func other(than noteID: UUID) -> UUID? {
        if a == noteID { return b }
        if b == noteID { return a }
        return nil
    }
}

// MARK: - 复习卡

struct ReviewCard: Identifiable, Codable, Hashable {
    var noteID: UUID
    var due: Date
    var ease: Double
    var intervalDays: Double
    var reps: Int
    var lapses: Int
    var lastReviewed: Date?

    var id: UUID { noteID }

    init(noteID: UUID, due: Date = Date()) {
        self.noteID = noteID
        self.due = due
        self.ease = 2.5
        self.intervalDays = 0
        self.reps = 0
        self.lapses = 0
        self.lastReviewed = nil
    }

    var isDue: Bool { due <= Date() }
}

// MARK: - 偏好键

enum Prefs {
    static let linkThreshold = "weave.linkThreshold"
    static let linkMaxPerNote = "weave.linkMaxPerNote"
    static let llmEnabled = "weave.llmEnabled"
    static let llmBaseURL = "weave.llmBaseURL"
    static let llmModel = "weave.llmModel"
    static let llmKey = "weave.llmKey"
    static let seeded = "weave.seeded"

    static var threshold: Double {
        let stored = UserDefaults.standard.double(forKey: linkThreshold)
        return stored > 0 ? stored : 0.18
    }

    static var maxLinksPerNote: Int {
        let stored = UserDefaults.standard.integer(forKey: linkMaxPerNote)
        return stored > 0 ? stored : 6
    }
}
