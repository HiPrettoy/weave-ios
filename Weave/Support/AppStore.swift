import Foundation
import Combine

/// 全部数据都在内存里维护，落盘是一份 JSON。
/// 选择这套方案的原因：目标设备是 iOS 16.7，SwiftData 用不了；
/// 而 Core Data 需要 .xcdatamodeld，在没有 Xcode 的环境里没法校验，出错概率高。
/// 笔记量级（几千条以内）用 JSON 全量读写完全够，逻辑也更透明。
final class AppStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var links: [NoteLink] = []
    @Published private(set) var cards: [ReviewCard] = []

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    private struct Snapshot: Codable {
        var version: Int
        var notes: [Note]
        var links: [NoteLink]
        var cards: [ReviewCard]
    }

    // MARK: - 生命周期

    init(filename: String = "weave-store.json") {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = directory.appendingPathComponent(filename)
        load()
        if notes.isEmpty && !UserDefaults.standard.bool(forKey: Prefs.seeded) {
            installSeed(SeedData.makeNotes())
        }
    }

    private func installSeed(_ seedNotes: [Note]) {
        notes = seedNotes
        cards = seedNotes.map { ReviewCard(noteID: $0.id) }
        rebuildLinks()
        UserDefaults.standard.set(true, forKey: Prefs.seeded)
        saveNow()
    }

    /// 设置页的「恢复示例数据」按钮
    func resetToSeed() {
        notes = SeedData.makeNotes()
        cards = notes.map { ReviewCard(noteID: $0.id) }
        rebuildLinks()
        UserDefaults.standard.set(true, forKey: Prefs.seeded)
        saveNow()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        notes = snapshot.notes
        links = snapshot.links
        cards = snapshot.cards
    }

    func saveNow() {
        let snapshot = Snapshot(version: 1, notes: notes, links: links, cards: cards)
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 输入时每敲一个字都会调到这里，所以写入是防抖的。
    /// 快照在调用线程上取（值类型，不会有并发读写问题），编码与落盘放到后台。
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = Snapshot(version: 1, notes: notes, links: links, cards: cards)
        let url = fileURL
        let item = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - 读

    func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    var sortedNotes: [Note] {
        notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    func card(for noteID: UUID) -> ReviewCard? {
        cards.first { $0.noteID == noteID }
    }

    var dueCards: [ReviewCard] {
        let now = Date()
        return cards.filter { $0.due <= now }.sorted { $0.due < $1.due }
    }

    func related(to note: Note, limit: Int = 8) -> [(Note, Double, LinkKind)] {
        var result: [(Note, Double, LinkKind)] = []
        for link in links {
            guard let otherID = link.other(than: note.id),
                  let other = notes.first(where: { $0.id == otherID }) else { continue }
            result.append((other, link.score, link.kind))
        }
        return Array(result.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    func linkCount(for noteID: UUID) -> Int {
        links.reduce(0) { partial, link in
            partial + ((link.a == noteID || link.b == noteID) ? 1 : 0)
        }
    }

    func degree(of noteID: UUID) -> Int { linkCount(for: noteID) }

    // MARK: - 写

    @discardableResult
    func add(content: String,
             title: String = "",
             tags: [String] = [],
             source: CaptureSource,
             imageData: Data? = nil) -> Note? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageData != nil else { return nil }

        let note = Note(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        content: trimmed,
                        tags: tags,
                        source: source,
                        imageData: imageData)
        notes.insert(note, at: 0)
        cards.append(ReviewCard(noteID: note.id))
        rebuildLinks()
        scheduleSave()
        return note
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date()
        notes[index] = updated
        scheduleSave()
    }

    func updateWithoutTouch(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        scheduleSave()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        links.removeAll { $0.a == note.id || $0.b == note.id }
        cards.removeAll { $0.noteID == note.id }
        rebuildLinks()
        scheduleSave()
    }

    func toggleFavorite(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].isFavorite.toggle()
        scheduleSave()
    }

    func grade(_ card: ReviewCard, grade: Int) {
        guard let index = cards.firstIndex(where: { $0.noteID == card.noteID }) else { return }
        cards[index] = SRS.apply(grade: grade, to: cards[index])
        scheduleSave()
    }

    func wipeAll() {
        notes = []
        links = []
        cards = []
        UserDefaults.standard.set(false, forKey: Prefs.seeded)
        saveNow()
    }

    // MARK: - 关联

    @discardableResult
    func rebuildLinks(threshold: Double = Prefs.threshold,
                      maxPerNote: Int = Prefs.maxLinksPerNote) -> Int {
        let result = AutoLinker.build(notes: notes,
                                      threshold: threshold,
                                      maxPerNote: maxPerNote)
        notes = result.notes
        links = result.links
        scheduleSave()
        return links.count
    }

    /// 语义检索：用整库重建 IDF 后比较余弦相似度
    func semanticSearch(_ query: String, limit: Int = 10) -> [(Note, Double)] {
        EmbeddingEngine.search(query: query, notes: notes, limit: limit)
    }

    /// 为单条笔记补充摘要与概念（需要 API Key）
    func enrich(_ note: Note, config: LLMConfig) async throws {
        let result = try await LLMEnricher.enrich(title: note.title,
                                                  content: note.content,
                                                  baseURL: config.baseURL,
                                                  apiKey: config.apiKey,
                                                  model: config.model)
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        if !result.summary.isEmpty { notes[index].summary = result.summary }
        if !result.concepts.isEmpty {
            var merged = notes[index].concepts
            for concept in result.concepts where !merged.contains(concept) {
                merged.append(concept)
            }
            notes[index].concepts = Array(merged.prefix(8))
        }
        for tag in result.tags where !notes[index].tags.contains(tag) {
            notes[index].tags.append(tag)
        }
        rebuildLinks()
        scheduleSave()
    }
}

struct LLMConfig {
    var baseURL: String
    var apiKey: String
    var model: String
}
