import XCTest
import UIKit
@testable import Weave

/// 存储层的两处自研件：ZIP 读写与图片仓库的文件名护栏。
/// 这两块一旦出错，用户丢的是备份和图片，所以必须钉死。
final class ZipArchiveTests: XCTestCase {

    func testRoundTripKeepsEveryEntry() {
        let entries = [
            ZipArchive.Entry(name: "weave-store.json", data: Data(#"{"version":2}"#.utf8)),
            ZipArchive.Entry(name: "Images/A.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            ZipArchive.Entry(name: "Images/B.jpg", data: Data(repeating: 0x41, count: 3000))
        ]
        let archive = ZipArchive.make(entries)

        // 标准 ZIP 的本地文件头就是 "PK\x03\x04"，系统的归档工具据此识别
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4B, 0x03, 0x04] as [UInt8])

        guard let read = ZipArchive.read(archive) else {
            return XCTFail("自己写的包自己读不回来")
        }
        XCTAssertEqual(read.count, entries.count)
        for entry in entries {
            XCTAssertEqual(read[entry.name], entry.data, "\(entry.name) 的内容对不上")
        }
    }

    func testEmptyArchiveIsStillReadable() {
        let archive = ZipArchive.make([])
        let read = ZipArchive.read(archive)
        XCTAssertNotNil(read)
        XCTAssertTrue(read?.isEmpty ?? false)
    }

    func testReadRejectsGarbage() {
        XCTAssertNil(ZipArchive.read(Data()))
        XCTAssertNil(ZipArchive.read(Data(repeating: 0x00, count: 100)))
        XCTAssertNil(ZipArchive.read(Data("随便一段文字，根本不是 zip".utf8)))
    }

    func testCRC32MatchesKnownVector() {
        // "123456789" 的 CRC-32 是 0xCBF43926，ZIP 规范用的就是这个多项式
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

final class NoteCodingTests: XCTestCase {

    private func encodeToString(_ note: Note) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(note)
        return String(decoding: data, as: UTF8.self)
    }

    func testEncodeSkipsEmbedding() throws {
        var note = Note(title: "标题", content: "正文")
        note.embedding = [Float](repeating: 0.5, count: 512)
        let json = try encodeToString(note)
        XCTAssertFalse(json.contains("embedding"), "向量占单条 JSON 的九成，不该落盘")
    }

    func testEncodeSkipsLegacyImageData() throws {
        var note = Note(title: "带图", content: "正文")
        note.legacyImageData = Data(repeating: 0x42, count: 4096)
        let json = try encodeToString(note)
        XCTAssertFalse(json.contains("imageData"), "图片已经外置，旧字段不该再写出来")
        XCTAssertLessThan(json.count, 1000, "除了正文不该还有大块数据")
    }

    func testEncodeKeepsImagePath() throws {
        let note = Note(title: "带图", content: "正文", imagePath: "ABC-123.jpg")
        let json = try encodeToString(note)
        XCTAssertTrue(json.contains("ABC-123.jpg"))
    }

    func testDecodeLegacyImageDataSurvives() throws {
        // 模拟老版本的 JSON：图片是 base64 内联的，没有 imagePath
        let legacy = """
        {"id":"6E1F0B4A-1111-4A2B-9C3D-4E5F60718293","title":"旧笔记","content":"正文",
         "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-02T10:00:00Z",
         "tags":["旧"],"source":"photo","summary":"","concepts":[],
         "imageData":"QkJCQg==","isFavorite":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(Note.self, from: Data(legacy.utf8))

        XCTAssertEqual(note.title, "旧笔记")
        XCTAssertNil(note.imagePath)
        XCTAssertEqual(note.legacyImageData, Data("BBBB".utf8), "老文件里的内联图要能读出来，才谈得上迁移")
        XCTAssertTrue(note.embedding.isEmpty, "读进来的笔记向量先留空，由连边重建时补")
    }

    func testDecodeFillsMissingFieldsWithDefaults() throws {
        // 只给最小字段：升级时新增的字段不该让整个文件读不出来
        let minimal = #"{"id":"6E1F0B4A-1111-4A2B-9C3D-4E5F60718294"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(Note.self, from: Data(minimal.utf8))

        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.tags, [])
        XCTAssertEqual(note.source, .text)
        XCTAssertEqual(note.updatedAt, note.createdAt)
        XCTAssertFalse(note.isFavorite)
    }
}

final class ImageStoreGuardTests: XCTestCase {

    /// 备份文件是别人给的，里面的文件名必须当不可信输入。
    /// 只验「拒绝」这一半：合法文件名在单测里会真的写盘，没必要污染模拟器沙盒。
    func testRestoreRejectsPathTraversal() {
        let hostile = [
            "../weave-store.json": Data("x".utf8),
            "Images/../../etc/passwd": Data("x".utf8),
            "..": Data("x".utf8),
            "": Data("x".utf8)
        ]
        let written = ImageStore.restore(hostile)
        XCTAssertTrue(written.isEmpty, "带路径分隔符或 .. 的文件名一律不许落盘")
    }

    func testDirectoryIsInsideDocuments() {
        let path = ImageStore.directory.path
        XCTAssertTrue(path.hasSuffix("/Images"), "图片目录应固定在 Documents/Images，实际：\(path)")
        XCTAssertFalse(path.contains("/tmp/"))
    }
}

/// 备份导入是唯一会「整体替换用户数据」的路径，两个入口（新 zip / 老 JSON）都得走通。
/// 真机上没法用合成事件驱动系统的文件选择器，所以这条链路只能靠这里的单测兜住。
final class AppStoreRestoreTests: XCTestCase {

    private var stores: [AppStore] = []

    override func tearDown() {
        // 每个用例用自己的空库，别污染模拟器里真正的 weave-store.json
        for store in stores { store.wipeAll() }
        stores = []
        super.tearDown()
    }

    private func makeStore() -> AppStore {
        let store = AppStore(filename: "test-restore-\(UUID().uuidString).json")
        store.wipeAll()
        stores.append(store)
        return store
    }

    private func snapshotJSON(notes: [Note], links: [NoteLink] = [], cards: [ReviewCard] = []) throws -> Data {
        // 用和 AppStore 一样的编码配置拼出清单文件
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let noteObjects = try JSONSerialization.jsonObject(with: encoder.encode(notes))
        let linkObjects = try JSONSerialization.jsonObject(with: encoder.encode(links))
        let cardObjects = try JSONSerialization.jsonObject(with: encoder.encode(cards))
        let body: [String: Any] = [
            "version": 2,
            "notes": noteObjects,
            "links": linkObjects,
            "cards": cardObjects
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    func testRestoreFromZipBringsBackNotesAndImages() throws {
        let note = Note(title: "带图的笔记", content: "正文", tags: ["备份"])
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        var noted = note
        noted.imagePath = "\(note.id.uuidString).jpg"

        let manifest = try snapshotJSON(notes: [noted],
                                        links: [],
                                        cards: [ReviewCard(noteID: note.id)])
        let archive = ZipArchive.make([
            ZipArchive.Entry(name: "weave-store.json", data: manifest),
            ZipArchive.Entry(name: "Images/\(note.id.uuidString).jpg", data: image)
        ])

        let store = makeStore()
        let count = try store.restore(from: archive)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].title, "带图的笔记")
        XCTAssertEqual(store.notes[0].imagePath, "\(note.id.uuidString).jpg")
        XCTAssertTrue(ImageStore.exists("\(note.id.uuidString).jpg"), "备份里的图片要真的落到 Documents/Images")
        XCTAssertEqual(store.cards.count, 1)
    }

    func testRestoreFromLegacyJSONMigratesInlineImage() throws {
        // 老备份的形状得手写：现在的 Note.encode 已经不写 imageData 了，
        // 用编码器造不出「旧版本导出的文件」，必须直接拼 JSON。
        let id = UUID()
        let png = try XCTUnwrap(UIImage(systemName: "photo")?.pngData(), "构造一张小图做样本")
        let note: [String: Any] = [
            "id": id.uuidString,
            "title": "老笔记",
            "content": "正文",
            "tags": ["旧备份"],
            "source": "photo",
            "createdAt": "2026-10-01T10:00:00Z",
            "updatedAt": "2026-10-01T10:00:00Z",
            "summary": "",
            "concepts": [],
            "isFavorite": false,
            "imageData": png.base64EncodedString()
        ]
        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "notes": [note],
            "links": [],
            "cards": [] as [Any]
        ])

        let store = makeStore()
        let count = try store.restore(from: legacyJSON)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.notes[0].id, id)
        XCTAssertNil(store.notes[0].legacyImageData, "导入后内联图应已转成文件")
        let path = try XCTUnwrap(store.notes[0].imagePath, "老备份里的图要能迁移成独立文件")
        XCTAssertTrue(ImageStore.exists(path))
        XCTAssertTrue(ImageStore.image(for: path) != nil, "迁移出的图片要能被读回来")
    }

    func testRestoreRejectsGarbage() {
        let store = makeStore()
        XCTAssertThrowsError(try store.restore(from: Data("这不是备份".utf8)))
        XCTAssertThrowsError(try store.restore(from: Data(repeating: 0x00, count: 64)))
    }

    func testRestoreDropsOrphanLinksAndCards() throws {
        // 备份里的关联/卡片指向了不存在的笔记：留着会让界面出现点不开的幽灵条目
        let note = Note(title: "只剩一条", content: "正文")
        let ghost = UUID()
        let manifest = try snapshotJSON(
            notes: [note],
            links: [NoteLink(a: note.id, b: ghost, score: 0.5, kind: .semantic)],
            cards: [ReviewCard(noteID: ghost)]
        )
        let store = makeStore()
        _ = try store.restore(from: manifest)

        XCTAssertTrue(store.links.isEmpty)
        XCTAssertTrue(store.cards.isEmpty)
    }
}

/// `BackupStore` 是「不靠系统文件选择器也能恢复」的那条路：
/// 文件放在 `Documents/Backups/`，设置页直接列出来点一下就导入。
/// 这里只验目录读写逻辑本身，不碰 UI。
final class BackupStoreTests: XCTestCase {
    private var created: [BackupStore.Item] = []

    override func tearDown() {
        for item in created { BackupStore.remove(item) }
        created = []
        super.tearDown()
    }

    /// 造一个只属于本用例的名字，避免和真机/其他用例留下的备份混淆
    private func unique(_ suffix: String) -> String {
        "test-\(UUID().uuidString.prefix(8))\(suffix)"
    }

    func testSaveThenListReturnsIt() throws {
        let name = unique(".weave")
        let url = try BackupStore.save(Data("hello".utf8), name: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        defer { created.append(BackupStore.Item(name: name, url: url, modified: Date(), bytes: 5)) }

        let items = BackupStore.list()
        let found = try XCTUnwrap(items.first { $0.name == name }, "刚写进去的备份要出现在列表里")
        XCTAssertEqual(found.bytes, 5)
        XCTAssertEqual(found.sizeText.isEmpty, false, "列表要能显示大小")
        XCTAssertEqual(found.modifiedText.isEmpty, false, "列表要能显示时间")
    }

    func testListIgnoresIrrelevantFiles() throws {
        let bad = unique(".txt")
        let good = unique(".json")
        let badURL = try BackupStore.save(Data("x".utf8), name: bad)
        let goodURL = try BackupStore.save(Data("y".utf8), name: good)
        defer {
            created.append(BackupStore.Item(name: bad, url: badURL, modified: Date(), bytes: 1))
            created.append(BackupStore.Item(name: good, url: goodURL, modified: Date(), bytes: 1))
        }

        let names = BackupStore.list().map(\.name)
        XCTAssertFalse(names.contains(bad), "只认 .weave 与 .json，别的扩展名不该混进恢复列表")
        XCTAssertTrue(names.contains(good), "旧版的纯 JSON 备份也要能被找到")
    }

    func testListIsNewestFirst() throws {
        let older = unique(".weave")
        let newer = unique(".weave")
        let olderURL = try BackupStore.save(Data("old".utf8), name: older)
        let newerURL = try BackupStore.save(Data("new".utf8), name: newer)
        defer {
            created.append(BackupStore.Item(name: older, url: olderURL, modified: Date(), bytes: 3))
            created.append(BackupStore.Item(name: newer, url: newerURL, modified: Date(), bytes: 3))
        }
        // 明确拉开修改时间，别依赖写入顺序碰巧一致
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                             ofItemAtPath: olderURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                                             ofItemAtPath: newerURL.path)

        let names = BackupStore.list().map(\.name)
        let newerIndex = try XCTUnwrap(names.firstIndex(of: newer))
        let olderIndex = try XCTUnwrap(names.firstIndex(of: older))
        XCTAssertLessThan(newerIndex, olderIndex, "最新的一份要排在最前面")
    }

    func testReadRoundTrip() throws {
        let name = unique(".weave")
        let payload = Data((0..<512).map { UInt8($0 % 251) })
        let url = try BackupStore.save(payload, name: name)
        defer { created.append(BackupStore.Item(name: name, url: url, modified: Date(), bytes: payload.count)) }

        let item = try XCTUnwrap(BackupStore.list().first { $0.name == name })
        XCTAssertEqual(try BackupStore.read(item), payload)
    }

    func testImportExternalKeepsOriginalAndDeduplicates() throws {
        // 用户从「文件」App 挑来的文件：要拷进 Backups，但原文件不能动
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(unique(".weave"))
        let payload = Data("external".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = try BackupStore.importExternal(source)
        created.append(BackupStore.Item(name: first.lastPathComponent, url: first, modified: Date(), bytes: payload.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "原始文件不能被搬走或删掉")
        XCTAssertEqual(try Data(contentsOf: first), payload)

        // 同名再导一次：不能覆盖已经躺着的那份
        let second = try BackupStore.importExternal(source)
        created.append(BackupStore.Item(name: second.lastPathComponent, url: second, modified: Date(), bytes: payload.count))
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent, "重名要加序号，别覆盖旧备份")
        XCTAssertTrue(second.lastPathComponent.contains("-2"))
    }

    func testRemoveDeletesFile() throws {
        let name = unique(".weave")
        let url = try BackupStore.save(Data("bye".utf8), name: name)
        let item = BackupStore.Item(name: name, url: url, modified: Date(), bytes: 3)
        BackupStore.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(BackupStore.list().map(\.name).contains(name))
    }
}
