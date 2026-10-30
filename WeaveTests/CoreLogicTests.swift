import XCTest
@testable import Weave

/// 间隔重复是本 App 的核心承诺之一（「记住该复习的东西」），
/// 而它的调度逻辑全是纯算术，最适合用测试钉死。
final class SRSReviewTests: XCTestCase {

    func testFirstSuccessSchedulesTomorrow() {
        let card = SRS.apply(grade: 2, to: ReviewCard(noteID: UUID()))
        XCTAssertEqual(card.reps, 1)
        XCTAssertEqual(card.intervalDays, 1, accuracy: 1e-9)
    }

    func testSecondSuccessSchedulesThreeDays() {
        var card = ReviewCard(noteID: UUID())
        card = SRS.apply(grade: 2, to: card)
        card = SRS.apply(grade: 2, to: card)
        XCTAssertEqual(card.reps, 2)
        XCTAssertEqual(card.intervalDays, 3, accuracy: 1e-9)
    }

    func testFailureResetsRepsAndCountsLapse() {
        var card = ReviewCard(noteID: UUID())
        card = SRS.apply(grade: 3, to: card)
        let easeBefore = card.ease
        card = SRS.apply(grade: 0, to: card)
        XCTAssertEqual(card.reps, 0, "忘了要重新开始")
        XCTAssertEqual(card.lapses, 1)
        XCTAssertLessThan(card.ease, easeBefore, "忘了应该让难度上升（ease 下降）")
        XCTAssertEqual(card.intervalDays, 0.02, accuracy: 1e-9, "约 30 分钟后重问")
    }

    func testEaseIsClampedToReasonableRange() {
        var card = ReviewCard(noteID: UUID())
        for _ in 0..<20 { card = SRS.apply(grade: 3, to: card) }
        XCTAssertLessThanOrEqual(card.ease, 2.8)
        XCTAssertGreaterThanOrEqual(card.ease, 1.3)
    }

    func testIntervalNeverExceedsOneYear() {
        var card = ReviewCard(noteID: UUID())
        for _ in 0..<60 { card = SRS.apply(grade: 3, to: card) }
        XCTAssertLessThanOrEqual(card.intervalDays, 365)
    }

    func testGradeIsClampedOutOfRange() {
        let low = SRS.apply(grade: -5, to: ReviewCard(noteID: UUID()))
        let high = SRS.apply(grade: 99, to: ReviewCard(noteID: UUID()))
        // 越界不应该崩，且低档按「忘了」处理、高档按「太简单」处理
        XCTAssertEqual(low.reps, 0)
        XCTAssertEqual(high.reps, 1)
    }

    func testDueDateMovesForward() {
        let before = Date()
        let card = SRS.apply(grade: 2, to: ReviewCard(noteID: UUID()))
        XCTAssertGreaterThan(card.due, before)
        XCTAssertNotNil(card.lastReviewed)
    }

    func testHumanizedPhrases() {
        XCTAssertEqual(SRS.humanized(0), "现在")
        XCTAssertEqual(SRS.humanized(1), "1 天后")
        XCTAssertEqual(SRS.humanized(40), "1 个月后")
        // 不足一小时（1/24 天）说「马上」，一小时到一天之间才按分钟算
        XCTAssertEqual(SRS.humanized(0.01), "马上")
        XCTAssertTrue(SRS.humanized(0.5).contains("分钟"))
    }
}

/// 导出是用户把数据带走的唯一出路，格式一旦坏了没人会发现
final class ExporterTests: XCTestCase {

    func testMarkdownContainsEveryNoteAndItsRelation() {
        let first = Note(title: "卡尔曼滤波", content: "线性高斯系统的最优估计")
        let second = Note(title: "粒子滤波", content: "非线性非高斯问题的近似推断")
        let link = NoteLink(a: first.id, b: second.id, score: 0.42, kind: .semantic)

        let markdown = Exporter.markdown(notes: [first, second], links: [link])

        XCTAssertTrue(markdown.contains("## 卡尔曼滤波"))
        XCTAssertTrue(markdown.contains("## 粒子滤波"))
        XCTAssertTrue(markdown.contains("共 2 条笔记，1 条关联"))
        // 关联两个方向都要出现：只看一边会让人以为关系是单向的
        XCTAssertTrue(markdown.contains("[[粒子滤波]]"))
        XCTAssertTrue(markdown.contains("[[卡尔曼滤波]]"))
    }

    func testMarkdownHandlesDanglingLink() {
        let note = Note(title: "只有一条", content: "正文")
        let ghost = NoteLink(a: note.id, b: UUID(), score: 0.5, kind: .tag)
        let markdown = Exporter.markdown(notes: [note], links: [ghost])
        // 指向不存在笔记的边应该被忽略，而不是崩掉或输出空标题
        XCTAssertTrue(markdown.contains("## 只有一条"))
        XCTAssertFalse(markdown.contains("[[]]"))
    }

    func testEmptyLibraryStillProducesHeader() {
        let markdown = Exporter.markdown(notes: [], links: [])
        XCTAssertTrue(markdown.hasPrefix("# 织识导出"))
        XCTAssertTrue(markdown.contains("共 0 条笔记"))
    }
}

/// LLM 的 URL 拼接与 JSON 抽取是最容易回归的地方：
/// 各家兼容接口的 baseURL 写法五花八门，改一次就得重新确认。
final class LLMEnricherTests: XCTestCase {

    func testEndpointAppendsVersionWhenMissing() {
        let url = LLMEnricher.endpoint(from: "https://api.deepseek.com")
        XCTAssertEqual(url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
    }

    func testEndpointKeepsExistingVersion() {
        let url = LLMEnricher.endpoint(from: "https://api.moonshot.cn/v1")
        XCTAssertEqual(url?.absoluteString, "https://api.moonshot.cn/v1/chat/completions")
    }

    func testEndpointKeepsFourthVersionSegment() {
        let url = LLMEnricher.endpoint(from: "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(url?.absoluteString, "https://open.bigmodel.cn/api/paas/v4/chat/completions")
    }

    func testEndpointDoesNotDoubleSuffix() {
        let url = LLMEnricher.endpoint(from: "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testEndpointTrimsTrailingSlashes() {
        let url = LLMEnricher.endpoint(from: "  https://example.com/v1/  ")
        XCTAssertEqual(url?.absoluteString, "https://example.com/v1/chat/completions")
    }

    func testEndpointRejectsBlank() {
        XCTAssertNil(LLMEnricher.endpoint(from: "   "))
    }

    func testModelCandidatesForBareHost() {
        let list = LLMEnricher.modelEndpointCandidates(from: "https://api.deepseek.com")
        XCTAssertEqual(list.map(\.absoluteString),
                       ["https://api.deepseek.com/v1/models",
                        "https://api.deepseek.com/models"])
    }

    func testModelCandidatesForVersionedHost() {
        let list = LLMEnricher.modelEndpointCandidates(from: "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(list.map(\.absoluteString),
                       ["https://open.bigmodel.cn/api/paas/v4/models"])
    }

    func testModelCandidatesStripChatCompletions() {
        let list = LLMEnricher.modelEndpointCandidates(from: "https://api.moonshot.cn/v1/chat/completions")
        XCTAssertEqual(list.first?.absoluteString, "https://api.moonshot.cn/v1/models")
    }

    func testParseModelIDsReadsDataArray() {
        let json = #"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#
        let ids = LLMEnricher.parseModelIDs(Data(json.utf8))
        XCTAssertEqual(ids, ["deepseek-chat", "deepseek-reasoner"])
    }

    func testParseModelIDsReadsModelsArray() {
        let json = #"{"models":[{"name":"qwen2.5:7b"},{"model":"llama3"}]}"#
        XCTAssertEqual(LLMEnricher.parseModelIDs(Data(json.utf8)), ["llama3", "qwen2.5:7b"])
    }

    func testParseModelIDsToleratesGarbage() {
        XCTAssertTrue(LLMEnricher.parseModelIDs(Data("<html>502</html>".utf8)).isEmpty)
    }

    func testParseExtractsPlainJSON() {
        let text = #"{"summary":"一句话","concepts":["A","B"],"tags":["x"]}"#
        let result = LLMEnricher.parse(text)
        XCTAssertEqual(result.summary, "一句话")
        XCTAssertEqual(result.concepts, ["A", "B"])
        XCTAssertEqual(result.tags, ["x"])
    }

    func testParseExtractsFromCodeFence() {
        let text = """
        ```json
        {"summary":"围栏里","concepts":[],"tags":[]}
        ```
        """
        XCTAssertEqual(LLMEnricher.parse(text).summary, "围栏里")
    }

    func testParseIgnoresBracesInProse() {
        // 模型在 JSON 前后补了说明文字，而且说明里带大括号：
        // 老实现取「第一个 { 到最后一个 }」会切出一段非法字符串。
        let text = """
        好的，下面是结果 {注意}：
        {"summary":"正确的那条","concepts":["X"],"tags":[]}
        希望有帮助 {完}
        """
        let result = LLMEnricher.parse(text)
        XCTAssertEqual(result.summary, "正确的那条", "应当取第一个括号配平的对象")
    }

    func testParseKeepsBracesInsideStrings() {
        let text = #"{"summary":"含 { 括号 的摘要","concepts":[],"tags":[]}"#
        XCTAssertEqual(LLMEnricher.parse(text).summary, "含 { 括号 的摘要")
    }

    func testParseReturnsEmptyOnUnparseableText() {
        let result = LLMEnricher.parse("模型今天不想输出 JSON")
        XCTAssertTrue(result.summary.isEmpty)
        XCTAssertTrue(result.concepts.isEmpty)
        XCTAssertTrue(result.tags.isEmpty)
    }
}

/// 笔记与关联的标识规则：pairKey 决定了「同一条边」怎么判等，
/// 写错会导致同一对笔记在库里存出两条方向相反的边。
final class ModelIdentityTests: XCTestCase {

    func testPairKeyIsOrderIndependent() {
        let a = UUID()
        let b = UUID()
        XCTAssertEqual(NoteLink.pairKey(a, b), NoteLink.pairKey(b, a))
    }

    func testPairKeyDiffersForDifferentPairs() {
        XCTAssertNotEqual(NoteLink.pairKey(UUID(), UUID()), NoteLink.pairKey(UUID(), UUID()))
    }

    func testLinkOtherReturnsOppositeEnd() {
        let a = UUID()
        let b = UUID()
        let link = NoteLink(a: a, b: b, score: 0.3, kind: .semantic)
        XCTAssertEqual(link.other(than: a), b)
        XCTAssertEqual(link.other(than: b), a)
        XCTAssertNil(link.other(than: UUID()))
    }

    func testLinkIDMatchesPairKey() {
        let a = UUID()
        let b = UUID()
        let link = NoteLink(a: a, b: b, score: 0.3, kind: .tag)
        XCTAssertEqual(link.id, NoteLink.pairKey(a, b))
    }

    func testDisplayTitleFallsBackToContentThenSource() {
        XCTAssertEqual(Note(title: "有标题", content: "正文").displayTitle, "有标题")
        XCTAssertEqual(Note(title: "", content: "第一行\n第二行").displayTitle, "第一行")
        // 回退文案已经进了 Localizable.xcstrings，英文环境下是 "Photo note"，
        // 所以断言也走同一张表，不然这条测试会随模拟器语言红掉。
        XCTAssertEqual(Note(title: "", content: "", source: .photo).displayTitle,
                       String(localized: "图片笔记"))
        XCTAssertEqual(Note(title: "", content: "", source: .voice).displayTitle,
                       String(localized: "语音笔记"))
    }

    func testFullTitleKeepsLongTitleIntact() {
        let long = String(repeating: "字", count: 40)
        // 导出与双链引用走 fullTitle：截断会把用户写的东西弄丢
        XCTAssertEqual(Note(title: long, content: "").fullTitle, long)
    }

    func testDisplayTitleTruncatesLongTitles() {
        let long = String(repeating: "字", count: 40)
        let title = Note(title: long, content: "").displayTitle
        XCTAssertEqual(title.count, 23, "22 个字加一个省略号")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testParseTagsSplitsAndDeduplicates() {
        XCTAssertEqual(parseTags("读书, 读书 #笔记  "), ["读书", "笔记"])
        XCTAssertEqual(parseTags(""), [])
    }

    func testMergeTagsKeepsExistingFirst() {
        let merged = mergeTags(existing: "旧标签", incoming: ["新标签", "旧标签"])
        XCTAssertEqual(parseTags(merged), ["旧标签", "新标签"])
    }
}
