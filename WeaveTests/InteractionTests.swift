import XCTest
@testable import Weave

/// `weave://` 是 App 唯一的外部入口 —— 快捷指令、书签都靠它把内容递进来。
/// 解析逻辑全是纯字符串处理，钉死之后改协议不会悄悄坏掉。
final class QuickAddTests: XCTestCase {

    private func parse(_ raw: String) -> QuickAdd.Draft? {
        guard let url = URL(string: raw) else {
            XCTFail("构造不出 URL: \(raw)")
            return nil
        }
        return QuickAdd.parse(url)
    }

    func testParsesTextAndTags() {
        let draft = parse("weave://add?text=%E8%B4%9D%E5%8F%B6%E6%96%AF&tags=%E5%AD%A6%E4%B9%A0,%E7%AE%97%E6%B3%95")
        XCTAssertEqual(draft?.text, "贝叶斯")
        XCTAssertEqual(draft?.tags, ["学习", "算法"])
    }

    func testAcceptsContentAsAliasForText() {
        XCTAssertEqual(parse("weave://add?content=hello")?.text, "hello")
    }

    /// 快捷指令里最省事的写法是不带等号：整段 query 就是正文
    func testBareQueryBecomesText() {
        XCTAssertEqual(parse("weave://add?just%20a%20thought")?.text, "just a thought")
    }

    func testParsesTitle() {
        XCTAssertEqual(parse("weave://add?text=body&title=%E6%A0%87%E9%A2%98")?.title, "标题")
    }

    func testAcceptsNewAsAction() {
        XCTAssertEqual(parse("weave://new?text=hi")?.text, "hi")
    }

    func testRejectsOtherSchemes() {
        XCTAssertNil(parse("https://example.com/add?text=hi"))
        XCTAssertNil(parse("weave2://add?text=hi"))
    }

    func testRejectsUnknownAction() {
        XCTAssertNil(parse("weave://delete?text=hi"))
    }

    func testRejectsEmptyText() {
        XCTAssertNil(parse("weave://add"))
        XCTAssertNil(parse("weave://add?text="))
        XCTAssertNil(parse("weave://add?text=%20%20"))
    }

    /// 同一个键出现两次时保留第一个，别让后面的悄悄覆盖
    func testFirstValueWins() {
        XCTAssertEqual(parse("weave://add?text=first&text=second")?.text, "first")
    }
}

/// 采集页删除之后给 6 秒撤销窗口。这里钉死 store 侧的装回逻辑：
/// 笔记、复习进度要回来，正文不能因为图片文件被清掉而丢。
final class DeleteUndoTests: XCTestCase {

    private var stores: [AppStore] = []

    override func tearDown() {
        for store in stores { store.wipeAll() }
        stores.removeAll()
        super.tearDown()
    }

    private func makeStore() -> AppStore {
        let store = AppStore(filename: "test-undo-\(UUID().uuidString).json")
        store.wipeAll()
        stores.append(store)
        return store
    }

    func testUndoRestoresNoteAndReviewCard() {
        let store = makeStore()
        guard let note = store.add(content: "贝叶斯推断的基本形式", source: .text) else {
            return XCTFail("add 失败")
        }
        // 先复习一次，让卡片带上进度 —— 撤销后进度不能丢
        if let card = store.card(for: note.id) {
            store.grade(card, grade: 2)
        }
        let progress = store.card(for: note.id)?.reps

        let bundle = store.remove(note)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNil(store.card(for: note.id))

        store.undoDelete(bundle)
        XCTAssertEqual(store.notes.map(\.id), [note.id])
        XCTAssertEqual(store.card(for: note.id)?.reps, progress)
    }

    /// 撤销窗口内图片文件还在；窗口过了才允许清理
    func testCommitDeletionRemovesImageOnlyAfterUndoWindow() {
        let store = makeStore()
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        guard let note = store.add(content: "带图的笔记", source: .photo, imageData: imageData),
              let path = note.imagePath else {
            return XCTFail("带图 add 失败")
        }
        XCTAssertTrue(ImageStore.exists(path))

        let bundle = store.remove(note)
        // 删除瞬间文件必须还在，否则撤销就恢复不出图了
        XCTAssertTrue(ImageStore.exists(path))

        store.undoDelete(bundle)
        XCTAssertTrue(ImageStore.exists(path))
        XCTAssertEqual(store.notes.first?.imagePath, path)

        // 再删一次，这次让窗口过期
        let second = store.remove(store.notes[0])
        store.commitDeletion(second)
        XCTAssertFalse(ImageStore.exists(path))
    }

    /// 图片在窗口期内被别处清掉了：正文与标签必须还在，只是退化成无图笔记
    func testUndoSurvivesMissingImageFile() {
        let store = makeStore()
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        guard let note = store.add(content: "正文不能丢", tags: ["标签"], source: .photo, imageData: imageData),
              let path = note.imagePath else {
            return XCTFail("带图 add 失败")
        }
        let bundle = store.remove(note)
        ImageStore.remove(path)   // 模拟被别的路径清掉

        store.undoDelete(bundle)
        XCTAssertEqual(store.notes.first?.content, "正文不能丢")
        XCTAssertEqual(store.notes.first?.tags, ["标签"])
        XCTAssertNil(store.notes.first?.imagePath)
    }

    /// 撤销之后关联要重新长出来（它们由 rebuildLinks 按当前阈值重算）
    func testUndoRebuildsLinks() {
        let store = makeStore()
        guard let a = store.add(content: "双链笔记把想法连起来，形成一张网", source: .text),
              let b = store.add(content: "双链笔记的价值在于让想法互相引用，形成网络", source: .text) else {
            return XCTFail("add 失败")
        }
        XCTAssertFalse(store.related(to: a, limit: 8).isEmpty)

        let bundle = store.remove(a)
        XCTAssertTrue(store.related(to: b, limit: 8).isEmpty)

        store.undoDelete(bundle)
        XCTAssertFalse(store.related(to: b, limit: 8).isEmpty)
    }

    /// 直接 delete 不留撤销窗口：图片立刻清掉
    func testDirectDeleteRemovesImageImmediately() {
        let store = makeStore()
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        guard let note = store.add(content: "详情页删的", source: .photo, imageData: imageData),
              let path = note.imagePath else {
            return XCTFail("带图 add 失败")
        }
        store.delete(store.note(id: note.id) ?? note)
        XCTAssertFalse(ImageStore.exists(path))
        XCTAssertTrue(store.notes.isEmpty)
    }
}

/// 提醒调度：只排一条、没有到期卡片就不排。
final class ReminderSchedulerTests: XCTestCase {

    func testNoReminderWhenNothingIsDue() {
        let scheduled = ReminderScheduler.reschedule(dueCount: 0, enabled: true, hour: 9, minute: 0)
        XCTAssertNil(scheduled, "没有卡片要复习时不该打扰")
    }

    func testNoReminderWhenDisabled() {
        let scheduled = ReminderScheduler.reschedule(dueCount: 5, enabled: false, hour: 9, minute: 0)
        XCTAssertNil(scheduled)
    }

    func testSchedulesOnNextNineAm() throws {
        let scheduled = try XCTUnwrap(
            ReminderScheduler.reschedule(dueCount: 3, enabled: true, hour: 9, minute: 0)
        )
        let parts = Calendar.current.dateComponents([.hour, .minute], from: scheduled)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertGreaterThan(scheduled, Date(), "最早一次提醒必须在将来")
        ReminderScheduler.cancel()
    }
}
