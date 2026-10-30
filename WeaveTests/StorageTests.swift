import XCTest
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
