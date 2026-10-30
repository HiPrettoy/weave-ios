import Foundation
import Combine
import UIKit

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
    /// 数据迁移（内联图片搬到独立文件）之后的一次性说明
    @Published private(set) var migrationNote: String?

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
        migrateInlineImages()
        if notes.isEmpty && !UserDefaults.standard.bool(forKey: Prefs.seeded) {
            installSeed(SeedData.makeNotes())
        }
    }

    /// 把老版本内联在 JSON 里的图搬成文件。
    ///
    /// 早期版本 `Note.imageData` 是 base64 塞在 JSON 里的，真机上一条带图笔记就能占 4.3 MB。
    /// 打开旧文件时顺手迁移：压到 1280px、写到 Documents/Images、把 JSON 里的那份丢掉。
    /// 顺带把「当年没压成功」的超大图重压一遍 —— 旧版判断长度用的是 point 不是像素，
    /// 3600×4800 的原图会原样存进来。
    private func migrateInlineImages() {
        var migrated = 0
        var resized = 0
        for offset in 0..<notes.count {
            guard let legacy = notes[offset].legacyImageData else { continue }
            notes[offset].legacyImageData = nil
            migrated += 1

            if let image = UIImage(data: legacy) {
                let pixels = ImageTool.pixelSize(of: image)
                if max(pixels.width, pixels.height) > 1280 { resized += 1 }
                if let data = ImageTool.compressed(image),
                   let name = ImageStore.save(data, name: notes[offset].id.uuidString) {
                    notes[offset].imagePath = name
                    continue
                }
            } else if let name = ImageStore.save(legacy, name: notes[offset].id.uuidString) {
                // 解不出图（极少见）：原样落盘，别把用户的图扔了
                notes[offset].imagePath = name
            }
        }
        guard migrated > 0 else { return }
        saveNow()
        migrationNote = String(localized: "已把 \(migrated) 张图片从数据库里搬到独立文件，其中 \(resized) 张顺手压小了。")
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
        let snapshot = Snapshot(version: 2, notes: notes, links: links, cards: cards)
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
        let snapshot = Snapshot(version: 2, notes: notes, links: links, cards: cards)
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
                        source: source)
        // 图片落成独立文件，JSON 里只留文件名 —— 原来 base64 内联，
        // 一条带图笔记就能占 4.3 MB，每次保存都要整份重写。
        if let imageData {
            note.imagePath = ImageStore.save(imageData, name: note.id.uuidString)
        }
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
        // embedding 是内存里的派生值，不跟着界面草稿回写
        updated.embedding = notes[offset].embedding
        updated.legacyImageData = nil
        notes[offset] = updated
        scheduleSave()
    }

    /// 直接删掉，不留撤销窗口。详情页有确认框，不需要反悔入口；
    /// 采集页要撤销窗口，走 remove / undoDelete / commitDeletion。
    func delete(_ note: Note) {
        let bundle = remove(note)
        commitDeletion(bundle)
    }

    /// 删掉一条笔记，并把「怎么把它装回去」需要的东西一起交出来。
    ///
    /// 采集页的最近列表里「⋯ › 删除」是一按就没的，没有确认框。
    /// 测试数据时无所谓，真数据下这就是事故 —— 所以删除返回一个可撤销的凭据，
    /// 由界面层决定给多久的反悔时间。图片文件不进凭据（可能有 200KB+），
    /// 只记文件名，撤销时文件还在原地就能直接用。
    @discardableResult
    func remove(_ note: Note) -> DeletedBundle {
        let bundle = DeletedBundle(note: note,
                                   card: card(for: note.id),
                                   imagePath: note.imagePath)
        // 图片先留着：撤销窗口内要能立刻拿回来。真正清理在 commitDeletion。
        notes.removeAll { $0.id == note.id }
        links.removeAll { $0.a == note.id || $0.b == note.id }
        cards.removeAll { $0.noteID == note.id }
        rebuildLinks()
        scheduleSave()
        return bundle
    }

    /// 撤销一次删除。笔记、它的复习卡（含复习进度）一起回来。
    /// 关联不用手动装回去 —— 下面的 rebuildLinks() 会按当前阈值重算，
    /// 同一份数据算出来的边是确定的，撤销之后连到的还是那几条。
    func undoDelete(_ bundle: DeletedBundle) {
        guard !notes.contains(where: { $0.id == bundle.note.id }) else { return }
        var note = bundle.note
        // 图片文件还在就继续用；期间被别的路径清掉了就退化成无图笔记，正文不能丢
        if let path = bundle.imagePath, ImageStore.exists(path) {
            note.imagePath = path
        } else {
            note.imagePath = nil
        }
        note.embedding = []
        notes.insert(note, at: 0)
        if let card = bundle.card, !cards.contains(where: { $0.noteID == card.noteID }) {
            cards.append(card)
        }
        rebuildLinks()
        scheduleSave()
    }

    /// 撤销窗口过了，真的把图片删掉。
    func commitDeletion(_ bundle: DeletedBundle) {
        guard !notes.contains(where: { $0.id == bundle.note.id }) else { return }
        if let path = bundle.imagePath { ImageStore.remove(path) }
    }

    /// 一次删除留下的凭据。只在内存里存在几秒，不落盘。
    struct DeletedBundle {
        var note: Note
        var card: ReviewCard?
        var imagePath: String?
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
        ImageStore.removeAll()
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

    /// 备份格式版本。1 = 早期「单个 JSON」，2 = 现在的 zip（JSON + 图片文件）。
    /// 读的时候两种情况都认，写的一律是 2。
    private static let backupManifestName = "weave-store.json"

    /// 整库备份，产出标准 zip：`weave-store.json` + `Images/<文件名>`。
    /// 只导出 Markdown 是不够的 —— 设备丢了复习进度和关联就再也拿不回来；
    /// 而图片外置之后只导 JSON 又会丢图，所以打包成 zip。
    func makeBackup() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(Snapshot(version: 2, notes: notes, links: links, cards: cards))

        var entries: [ZipArchive.Entry] = [
            ZipArchive.Entry(name: Self.backupManifestName, data: json)
        ]
        let referenced = Set(notes.compactMap(\.imagePath))
        let images = ImageStore.collect(referenced: referenced)
        for (filename, data) in images.sorted(by: { $0.key < $1.key }) {
            entries.append(ZipArchive.Entry(name: "Images/\(filename)", data: data))
        }
        return ZipArchive.make(entries)
    }

    /// 导入备份，返回恢复的笔记条数。调用方负责二次确认 —— 这会整体替换现有数据。
    /// 同时接受两种格式：老的纯 JSON 备份，和新的 zip 备份。
    @discardableResult
    func restore(from data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var snapshot: Snapshot?
        var images: [String: Data] = [:]

        // 先试 zip：ZIP 本地文件头是 "PK\x03\x04"
        if data.count > 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B {
            guard let files = ZipArchive.read(data),
                  let manifest = files[Self.backupManifestName],
                  let decoded = try? decoder.decode(Snapshot.self, from: manifest) else {
                throw BackupError.unreadable
            }
            snapshot = decoded
            for (name, content) in files where name.hasPrefix("Images/") {
                let filename = String(name.dropFirst("Images/".count))
                images[filename] = content
            }
        } else if let decoded = try? decoder.decode(Snapshot.self, from: data) {
            // 老格式：单个 JSON。图片在旧备份里还是 base64 内联的，
            // 下面赋值后会走一次 migrateInlineImages。
            snapshot = decoded
        }

        guard let snapshot else { throw BackupError.unreadable }

        // 备份文件是别人给的，不能盲信：关联与复习卡必须都指向存在的笔记，
        // 否则界面里会出现点不开的幽灵条目。
        let ids = Set(snapshot.notes.map(\.id))
        var notes = snapshot.notes
        // 图片丢了的笔记不该整条丢掉 —— 正文和标签还是用户写的东西。
        // 只把指向不存在文件的 imagePath 清掉，界面上退化成纯文字笔记。
        // 文件本地还在的，顺手读进 images，免得下面清目录时把它删了。
        for offset in 0..<notes.count {
            guard let path = notes[offset].imagePath else { continue }
            if images[path] != nil { continue }
            if let existing = try? Data(contentsOf: ImageStore.url(for: path)) {
                images[path] = existing
            } else {
                notes[offset].imagePath = nil
            }
        }
        let links = snapshot.links.filter { ids.contains($0.a) && ids.contains($0.b) }
        let cards = snapshot.cards.filter { ids.contains($0.noteID) }

        // 覆盖之前把当前数据留一份：导入错了还能捞回来。
        // 落到 Backups 目录而不是 Documents 根，这样它在设置页的列表里也看得见，
        // 不需要靠系统文件选择器去翻盘。出错不阻断，只是少一层保险。
        let stamp = Formatters.fileStamp.string(from: Date())
        try? BackupStore.save(makeBackup(), name: "restore-previous-\(stamp).weave")

        // 丢掉在途的防抖写：它带着旧快照，没必要再落一次盘
        saveWorkItem?.cancel()
        saveWorkItem = nil

        // 图片先落地：JSON 里引用的是文件名，文件不到笔记就成空图
        ImageStore.removeAll()
        if !images.isEmpty { ImageStore.restore(images) }

        // 老备份里的内联图在这里再转一次
        for offset in 0..<notes.count where notes[offset].legacyImageData != nil {
            guard let legacy = notes[offset].legacyImageData,
                  let image = UIImage(data: legacy),
                  let compressed = ImageTool.compressed(image),
                  let name = ImageStore.save(compressed, name: notes[offset].id.uuidString) else {
                notes[offset].legacyImageData = nil
                continue
            }
            notes[offset].imagePath = name
            notes[offset].legacyImageData = nil
        }

        self.notes = notes
        self.links = links
        self.cards = cards
        UserDefaults.standard.set(true, forKey: Prefs.seeded)
        saveNow()
        return notes.count
    }

    /// 写一份备份到 `Documents/Backups/`，返回它的 URL（分享面板与列表都用这个）。
    ///
    /// 落在 Backups 而不是临时目录，是因为临时目录会被系统回收，
    /// 而用户可能过一会儿才想起来要分享；顺便让这份文件在「文件」App 里也看得见。
    @discardableResult
    func writeBackupFile() throws -> URL {
        let name = "weave-\(Formatters.fileStamp.string(from: Date())).weave"
        return try BackupStore.save(try makeBackup(), name: name)
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

enum BackupError: LocalizedError {
    case unreadable
    case unwritable

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "既不是 .weave 压缩包，也不是旧版的 JSON 文件")
        case .unwritable:
            return String(localized: "写不进 Backups 目录，设备存储可能满了")
        }
    }
}
