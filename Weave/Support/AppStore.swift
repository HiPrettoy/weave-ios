import Foundation
import Combine

/// 记录「磁盘上已经是第几代快照」，用来丢弃迟到的旧快照。
/// 单独抽成一个带锁的小对象，免得在后台闭包里直接改 AppStore 的存储属性。
private final class SaveLedger {
    private let lock = NSLock()
    private var written: UInt64 = 0

    /// 这份快照比磁盘上的更新吗？旧的就别再写回去把新的盖掉。
    func isNewer(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation > written
    }

    /// 写成功之后才登记，失败时留白让后面那份继续写
    func commit(_ generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if generation > written { written = generation }
    }
}

/// 全部数据都在内存里维护，落盘是一份 JSON。
/// 选择这套方案的原因：目标设备是 iOS 16.7，SwiftData 用不了；
/// 而 Core Data 需要 .xcdatamodeld，在没有 Xcode 的环境里没法校验，出错概率高。
/// 笔记量级（几千条以内）用 JSON 全量读写完全够，逻辑也更透明。
final class AppStore: ObservableObject {
    @Published private(set) var notes: [Note] = [] {
        didSet {
            noteIndexDirty = true
            // 语料依赖每条笔记的分词结果，笔记一动就作废。
            // 记版本号而不是每次重算指纹 —— 前缀校验本身就要遍历全库。
            corpusRevision &+= 1
        }
    }
    @Published private(set) var links: [NoteLink] = []
    @Published private(set) var cards: [ReviewCard] = [] {
        didSet { cardIndexDirty = true }
    }

    /// 载入时如果文件损坏，这里会留下说明，界面据此提示用户而不是默默清空
    @Published private(set) var loadIssue: String?

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    /// 串行 IO 队列：saveNow 与防抖写都在这里排队，保证磁盘上永远是「最后提交」的那份，
    /// 不会出现旧快照盖掉新快照。原来两者各自往 global 并发队列里丢，顺序不确定。
    private static let ioQueue = DispatchQueue(label: "app.weave.store.io", qos: .utility)

    /// 主线程自增，标记每次快照的新旧
    private var saveGeneration: UInt64 = 0
    /// 已落盘的最高代号，跨线程共享
    private let ledger = SaveLedger()

    /// id → 笔记下标的索引。原来 note(id:)、related(to:)、card(for:)
    /// 全是在数组里线性扫，详情页每次 body 都要跑一遍。
    /// 用「脏标记 + 首次访问时重建」，比每次写入都同步重建便宜得多。
    private var noteIndex: [UUID: Int] = [:]
    private var noteIndexDirty = true
    private var cardIndex: [UUID: Int] = [:]
    private var cardIndexDirty = true

    /// 关联重建时顺带算好的整库语料，语义检索直接复用，
    /// 避免每敲一个字就把全库重新分词一次。
    private var corpus: SemanticCorpus?
    /// 语料对应的 notes 版本号；重建关联时对齐，任何一次 notes 写入都会让它失配
    private var corpusRevision: UInt64 = 0
    private var corpusBuiltAt: UInt64 = .max

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

    private var backupURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".bak")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        guard let data = try? Data(contentsOf: fileURL) else {
            loadIssue = String(localized: "存储文件读不出来，本次以空库启动。原文件保留在 Documents/\(fileURL.lastPathComponent)。")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            notes = snapshot.notes
            links = snapshot.links
            cards = snapshot.cards
            refreshBackupIfStale(with: data)
            return
        }

        // 解码失败：先把坏文件另存一份留证，再尝试回退到上一次的好副本。
        // 原来这里直接 return，用户看到的是空库，而且下一次保存会把坏文件盖掉，
        // 数据就真的没了。
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantine = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
        try? data.write(to: quarantine, options: .atomic)

        if let backup = try? Data(contentsOf: backupURL),
           let snapshot = try? decoder.decode(Snapshot.self, from: backup),
           !snapshot.notes.isEmpty {
            notes = snapshot.notes
            links = snapshot.links
            cards = snapshot.cards
            loadIssue = String(localized: "存储文件损坏，已回退到上一次备份（\(snapshot.notes.count) 条笔记）。损坏的文件已另存为 \(quarantine.lastPathComponent)。")
            return
        }

        loadIssue = String(localized: "存储文件损坏且没有可用备份，本次以空库启动。损坏的文件已另存为 \(quarantine.lastPathComponent)。")
    }

    /// 读成功后刷新 .bak。放到 IO 队列上做，别让启动等一次整库复制。
    private func refreshBackupIfStale(with data: Data) {
        let target = backupURL
        Self.ioQueue.async {
            if let existing = try? Data(contentsOf: target), existing == data { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    func saveNow() {
        let generation = nextGeneration()
        let snapshot = Snapshot(version: 1, notes: notes, links: links, cards: cards)
        let url = fileURL
        let ledger = self.ledger
        // 值类型快照在调用线程取好，编码与落盘全部在串行队列上，天然有序。
        Self.ioQueue.async {
            guard ledger.isNewer(generation) else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            ledger.commit(generation)
        }
    }

    /// 输入时每敲一个字都会调到这里，所以写入是防抖的。
    /// 快照在调用线程上取（值类型，不会有并发读写问题），编码与落盘放到串行队列。
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let generation = nextGeneration()
        let snapshot = Snapshot(version: 1, notes: notes, links: links, cards: cards)
        let url = fileURL
        let ledger = self.ledger
        let item = DispatchWorkItem {
            guard ledger.isNewer(generation) else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            ledger.commit(generation)
        }
        saveWorkItem = item
        Self.ioQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func nextGeneration() -> UInt64 {
        saveGeneration += 1
        return saveGeneration
    }

    // MARK: - 读

    /// 下标索引是懒建的：写入只标脏，真正查的时候才重建一次
    private func rebuildNoteIndexIfNeeded() {
        guard noteIndexDirty else { return }
        noteIndex.removeAll(keepingCapacity: true)
        noteIndex.reserveCapacity(notes.count)
        for (offset, note) in notes.enumerated() {
            noteIndex[note.id] = offset
        }
        noteIndexDirty = false
    }

    private func rebuildCardIndexIfNeeded() {
        guard cardIndexDirty else { return }
        cardIndex.removeAll(keepingCapacity: true)
        cardIndex.reserveCapacity(cards.count)
        for (offset, card) in cards.enumerated() {
            cardIndex[card.noteID] = offset
        }
        cardIndexDirty = false
    }

    func note(id: UUID) -> Note? {
        rebuildNoteIndexIfNeeded()
        guard let offset = noteIndex[id], offset < notes.count else { return nil }
        return notes[offset]
    }

    var sortedNotes: [Note] {
        notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    func card(for noteID: UUID) -> ReviewCard? {
        rebuildCardIndexIfNeeded()
        guard let offset = cardIndex[noteID], offset < cards.count else { return nil }
        return cards[offset]
    }

    var dueCards: [ReviewCard] {
        let now = Date()
        return cards.filter { $0.due <= now }.sorted { $0.due < $1.due }
    }

    func related(to note: Note, limit: Int = 8) -> [(Note, Double, LinkKind)] {
        rebuildNoteIndexIfNeeded()
        var result: [(Note, Double, LinkKind)] = []
        for link in links {
            guard let otherID = link.other(than: note.id),
                  let offset = noteIndex[otherID],
                  offset < notes.count else { continue }
            result.append((notes[offset], link.score, link.kind))
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
             imageData: Data? = nil,
             summary: String = "",
             concepts: [String] = []) -> Note? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageData != nil else { return nil }

        var note = Note(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        content: trimmed,
                        tags: tags,
                        source: source,
                        imageData: imageData)
        // 采集页里如果用过「AI 提炼」，概括和概念一起带进来，详情页直接就是整理好的样子
        note.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        note.concepts = Array(concepts.prefix(8))
        notes.insert(note, at: 0)
        cards.append(ReviewCard(noteID: note.id))
        rebuildLinks()
        scheduleSave()
        return note
    }

    func update(_ note: Note) {
        rebuildNoteIndexIfNeeded()
        guard let offset = noteIndex[note.id], offset < notes.count else { return }
        var updated = note
        updated.updatedAt = Date()
        notes[offset] = updated
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
        rebuildNoteIndexIfNeeded()
        guard let offset = noteIndex[note.id], offset < notes.count else { return }
        notes[offset].isFavorite.toggle()
        scheduleSave()
    }

    func grade(_ card: ReviewCard, grade: Int) {
        rebuildCardIndexIfNeeded()
        guard let offset = cardIndex[card.noteID], offset < cards.count else { return }
        cards[offset] = SRS.apply(grade: grade, to: cards[offset])
        scheduleSave()
    }

    func wipeAll() {
        notes = []
        links = []
        cards = []
        // 必须置 true：置 false 会让下一次 init 的「空库且未播种」判断成立，
        // 用户清空数据后重启又被灌回 6 条示例（与 SeedData 的注释相反）。
        UserDefaults.standard.set(true, forKey: Prefs.seeded)
        saveNow()
    }

    // MARK: - 关联

    @discardableResult
    func rebuildLinks(threshold: Double = Prefs.threshold,
                      maxPerNote: Int = Prefs.maxLinksPerNote) -> Int {
        let result = AutoLinker.build(notes: notes,
                                      threshold: threshold,
                                      maxPerNote: maxPerNote)
        // 先贴向量再赋值：AutoLinker 已经把每条笔记的 embedding 写好，
        // 语料也跟着一起缓存下来给语义检索用。
        corpus = result.corpus
        notes = result.notes
        links = result.links
        // notes 的 didSet 已经把版本号推进一格，语料正好对应这一版
        corpusBuiltAt = corpusRevision
        scheduleSave()
        return links.count
    }

    /// 语义检索。语料缓存有效时直接用，不再每次重建 IDF —— 原来每敲一个字
    /// 都要把全库重新分词一遍，这在几百条笔记时是肉眼可见的卡顿。
    func semanticSearch(_ query: String, limit: Int = 10) -> [(Note, Double)] {
        if corpus == nil || corpusBuiltAt != corpusRevision {
            corpus = EmbeddingEngine.corpus(for: notes)
            corpusBuiltAt = corpusRevision
        }
        guard let corpus else { return [] }
        return EmbeddingEngine.search(query: query, notes: notes, corpus: corpus, limit: limit)
    }

    // MARK: - 备份 / 恢复

    /// 整库备份：与磁盘上那份 JSON 同格式，可以直接拷走或再导入。
    /// 只导出 Markdown 是不够的 —— 设备丢了复习进度和关联就再也拿不回来。
    func makeBackup() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Snapshot(version: 1, notes: notes, links: links, cards: cards))
    }

    /// 导入备份，返回恢复的笔记条数。调用方负责二次确认 —— 这会整体替换现有数据。
    @discardableResult
    func restore(from data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: data)

        // 备份文件是别人给的，不能盲信：关联与复习卡必须都指向存在的笔记，
        // 否则界面里会出现点不开的幽灵条目。
        let ids = Set(snapshot.notes.map(\.id))
        let notes = snapshot.notes
        let links = snapshot.links.filter { ids.contains($0.a) && ids.contains($0.b) }
        let cards = snapshot.cards.filter { ids.contains($0.noteID) }

        // 覆盖之前把当前数据留在 Documents 里：导入错了还能捞回来。
        // 出错不阻断，只是少一层保险。
        let stamp = Int(Date().timeIntervalSince1970)
        let safety = fileURL.deletingLastPathComponent()
            .appendingPathComponent("weave-before-restore-\(stamp).weave")
        try? makeBackup().write(to: safety, options: .atomic)

        // 丢掉在途的防抖写：它带着旧快照，没必要再落一次盘
        saveWorkItem?.cancel()
        saveWorkItem = nil
        self.notes = notes
        self.links = links
        self.cards = cards
        UserDefaults.standard.set(true, forKey: Prefs.seeded)
        saveNow()
        return notes.count
    }

    /// 写一个临时备份文件，交给系统的分享面板 / 文件选择器
    func writeBackupFile() throws -> URL {
        let name = "weave-\(Formatters.fileStamp.string(from: Date())).weave"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try makeBackup().write(to: url, options: .atomic)
        return url
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
