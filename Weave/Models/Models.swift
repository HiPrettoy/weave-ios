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
        case .text: return String(localized: "文字")
        case .voice: return String(localized: "语音")
        case .photo: return String(localized: "拍照")
        case .manual: return String(localized: "手记")
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
        case .semantic: return String(localized: "语义相近")
        case .tag: return String(localized: "共同标签")
        case .temporal: return String(localized: "同一时段")
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
    /// 图片文件名（落在 `Documents/Images/` 下）。**只存文件名不存绝对路径**：
    /// iOS 沙盒目录在升级或重装后会变，存绝对路径会在某次更新后全部失效。
    var imagePath: String?
    var isFavorite: Bool
    /// 512 维本地向量，用于相似度计算；空数组表示还没算过。
    /// **不落盘** —— 它占单条笔记 JSON 的 90%，却随时能由正文重算出来。
    var embedding: [Float]

    /// 旧版本把图片 base64 塞在 JSON 里。这里只用于「读旧文件 + 迁移成图片文件」，
    /// 解码后由 AppStore 搬到 `Documents/Images/` 并清空，**从不参与编码**。
    var legacyImageData: Data?

    private enum CodingKeys: String, CodingKey {
        case id, title, content, createdAt, updatedAt, tags, source
        case summary, concepts, imagePath, imageData, isFavorite
    }

    init(id: UUID = UUID(),
         title: String = "",
         content: String = "",
         tags: [String] = [],
         source: CaptureSource = .text,
         createdAt: Date = Date(),
         imagePath: String? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.source = source
        self.summary = ""
        self.concepts = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.imagePath = imagePath
        self.isFavorite = false
        self.embedding = []
        self.legacyImageData = nil
    }

    // 手写 Codable 而不是让编译器合成：要跳过 embedding 与 legacyImageData，
    // 同时又能读得懂老版本留下的 imageData 字段。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try container.decodeIfPresent(CaptureSource.self, forKey: .source) ?? .text
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        concepts = try container.decodeIfPresent([String].self, forKey: .concepts) ?? []
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        legacyImageData = try container.decodeIfPresent(Data.self, forKey: .imageData)

        let created = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = created
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        embedding = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(tags, forKey: .tags)
        try container.encode(source, forKey: .source)
        try container.encode(summary, forKey: .summary)
        try container.encode(concepts, forKey: .concepts)
        try container.encodeIfPresent(imagePath, forKey: .imagePath)
        try container.encode(isFavorite, forKey: .isFavorite)
        // 刻意不写 embedding，也不写 legacyImageData
    }

    /// 不截断的标题：标题为空时退回正文首行，再退回来源。
    /// 导出与双链引用必须用这个 —— 截断的标题写进 Markdown 会把用户的内容弄丢。
    var fullTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            switch source {
            case .photo: return String(localized: "图片笔记")
            case .voice: return String(localized: "语音笔记")
            default: return String(localized: "无标题笔记")
            }
        }
        return trimmed
    }

    /// 界面用的标题：统一截到 22 个字，避免长标题在列表与图谱里整条溢出。
    var displayTitle: String {
        let full = fullTitle
        return full.count > 22 ? String(full.prefix(22)) + "…" : full
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
    /// 复习提醒：开关 + 每天几点 + 已排到的卡片数（用来避免每次都重排）
    static let remindEnabled = "weave.remindEnabled"
    static let remindHour = "weave.remindHour"
    static let remindMinute = "weave.remindMinute"

    static var threshold: Double {
        let stored = UserDefaults.standard.double(forKey: linkThreshold)
        return stored > 0 ? stored : 0.18
    }

    static var maxLinksPerNote: Int {
        let stored = UserDefaults.standard.integer(forKey: linkMaxPerNote)
        return stored > 0 ? stored : 6
    }

    static var reminderEnabled: Bool {
        UserDefaults.standard.bool(forKey: remindEnabled)
    }

    /// 默认早上 9 点。布尔量单独存，时/分缺省用 9:00。
    static var reminderHour: Int {
        UserDefaults.standard.object(forKey: remindHour) == nil
            ? 9
            : UserDefaults.standard.integer(forKey: remindHour)
    }

    static var reminderMinute: Int {
        UserDefaults.standard.integer(forKey: remindMinute)
    }
}
