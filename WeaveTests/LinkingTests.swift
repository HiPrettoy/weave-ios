import XCTest
@testable import Weave

/// 关联与检索是这台 App 的独有逻辑，也是改动最频繁的地方，
/// 但之前完全没有测试 —— 唯一的闸门是推上去之后 CI 编不过。
/// 这里先覆盖「纯函数」的部分：不碰文件、不碰网络、不碰 UI。
final class LinkingTests: XCTestCase {

    // MARK: - 分词

    func testTokenizerSplitsChineseIntoCharactersAndBigrams() {
        let tokens = TextTokenizer.tokens(in: "贝叶斯推断")
        // 单字 4 个 + 相邻二元组 3 个
        XCTAssertTrue(tokens.contains("贝"))
        XCTAssertTrue(tokens.contains("贝叶"))
        XCTAssertTrue(tokens.contains("叶斯"))
        XCTAssertTrue(tokens.contains("推断"))
        XCTAssertEqual(Set(tokens).count, tokens.count, "不应该出现重复 token")
    }

    func testTokenizerDropsChineseStopwords() {
        let tokens = TextTokenizer.tokens(in: "的了是")
        XCTAssertTrue(tokens.isEmpty, "全是停用字时不该产出 token，实际：\(tokens)")
    }

    func testTokenizerDropsBigramsMadeOfStopwords() {
        // 单字都是停用字时，拼出来的二元组同样是噪音（「的了」「了是」）。
        // 这类桶会被大量无关笔记共享，既白占 512 维又让倒排候选失真。
        let tokens = TextTokenizer.tokens(in: "我的了这个东西")
        for token in tokens where token.count == 2 {
            XCTAssertFalse(token == "的了" || token == "了是" || token == "的是",
                           "停用字拼出来的二元组不该入选，实际：\(tokens)")
        }
    }

    func testTokenizerHandlesLatinWords() {
        let tokens = TextTokenizer.tokens(in: "Bayesian inference, 2024")
        XCTAssertTrue(tokens.contains("bayesian"))
        XCTAssertTrue(tokens.contains("inference"))
        XCTAssertTrue(tokens.contains("2024"))
    }

    func testTokenizerDropsSingleLatinLetter() {
        let tokens = TextTokenizer.tokens(in: "a b c")
        XCTAssertTrue(tokens.isEmpty, "单字母不构成词，实际：\(tokens)")
    }

    // MARK: - 向量与语料

    func testSameTextProducesIdenticalVector() {
        let notes = [makeNote(content: "卡尔曼滤波用于状态估计"),
                     makeNote(content: "卡尔曼滤波用于状态估计")]
        let corpus = EmbeddingEngine.corpus(for: notes)
        XCTAssertEqual(corpus.vectors.count, 2)
        XCTAssertEqual(corpus.vectors[0], corpus.vectors[1])
        XCTAssertEqual(corpus.vectors[0].count, EmbeddingEngine.dimensions)
    }

    func testCosineOfIdenticalVectorIsOne() {
        let vector = EmbeddingEngine.vector(for: ["卡尔曼", "滤波"],
                                            index: CorpusIndex(documentCount: 2,
                                                               documentFrequency: [1: 1, 2: 1]))
        XCTAssertEqual(EmbeddingEngine.cosine(vector, vector), 1.0, accuracy: 1e-5)
    }

    func testCosineOfMismatchedLengthIsZero() {
        XCTAssertEqual(EmbeddingEngine.cosine([1, 0], [1, 0, 0]), 0)
        XCTAssertEqual(EmbeddingEngine.cosine([], [1, 0]), 0)
    }

    func testEmptyNoteGetsEmptyVectorAndIsNotLinked() {
        let empty = makeNote(content: "")
        let other = makeNote(content: "粒子滤波解决非线性非高斯问题")
        let result = AutoLinker.build(notes: [empty, other], threshold: 0.18, maxPerNote: 6)
        XCTAssertTrue(result.notes[0].embedding.isEmpty, "没有可索引文字的笔记不该有向量")
        XCTAssertFalse(result.links.contains { $0.a == empty.id || $0.b == empty.id },
                       "空向量笔记不该靠时间邻近硬连出关联")
    }

    // MARK: - 连边

    func testSimilarNotesGetLinked() {
        let a = makeNote(content: "双链笔记让知识之间形成网络，而不是一条条孤立的记录")
        let b = makeNote(content: "双链笔记的价值在于知识之间形成网络，避免孤立记录")
        let result = AutoLinker.build(notes: [a, b], threshold: 0.18, maxPerNote: 6)
        XCTAssertEqual(result.links.count, 1, "这两条应当连上，实际连了 \(result.links.count) 条")
        if let link = result.links.first {
            XCTAssertGreaterThanOrEqual(link.score, 0.18)
            XCTAssertEqual(Set([link.a, link.b]).count, 2)
        }
    }

    func testIrrelevantNotesStayApart() {
        let a = makeNote(content: "贝叶斯推断用先验更新后验概率")
        let b = makeNote(content: "今天下午去超市买了牛奶和面包")
        let result = AutoLinker.build(notes: [a, b], threshold: 0.45, maxPerNote: 6)
        // 高阈值下这两条不该连；用 0.45 是为了避开「同一时段」那 0.10 的兜底分。
        XCTAssertTrue(result.links.isEmpty, "无关的两条不该连，实际：\(result.links.map { $0.score })")
    }

    func testMaxPerNoteIsSymmetric() {
        // 5 条内容相近的笔记，每条最多连 2 条：配额必须两个方向都算，
        // 否则排在前面的笔记会占满配额，后面的连不到任何东西。
        // 用 2 而不是 1：把配额卡到 1 时，5 个点最多只能配出 2 条边（最大匹配），
        // 必然有笔记连不到，那考的是图的奇偶性而不是配额逻辑。
        let notes = (0..<5).map { index in
            makeNote(content: "间隔重复与遗忘曲线 \(index)",
                     tags: ["复习"],
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60))
        }
        let result = AutoLinker.build(notes: notes, threshold: 0.10, maxPerNote: 2)
        var degree: [UUID: Int] = [:]
        for link in result.links {
            degree[link.a, default: 0] += 1
            degree[link.b, default: 0] += 1
        }
        for note in notes {
            XCTAssertGreaterThan(degree[note.id] ?? 0, 0, "每条笔记都该至少连到一条")
            XCTAssertLessThanOrEqual(degree[note.id] ?? 0, 2, "配额是硬上限，两个方向都要守")
        }
        XCTAssertLessThanOrEqual(result.links.count, notes.count * 2)
    }

    func testNoDuplicateLinks() {
        let notes = (0..<6).map { makeNote(content: "费曼学习法的第 \($0) 种用法") }
        let result = AutoLinker.build(notes: notes, threshold: 0.10, maxPerNote: 6)
        let keys = result.links.map(\.id)
        XCTAssertEqual(Set(keys).count, keys.count, "同一对笔记只能出现一条边")
    }

    func testSingleNoteProducesNoLinks() {
        let result = AutoLinker.build(notes: [makeNote(content: "只有一条")],
                                      threshold: 0.18,
                                      maxPerNote: 6)
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertNil(result.corpus, "单条笔记不做语料计算")
    }

    // MARK: - 语义检索

    func testSemanticSearchPrefersTheRelevantNote() {
        let notes = [
            makeNote(content: "卡尔曼滤波处理线性高斯系统的状态估计"),
            makeNote(content: "粒子滤波处理非线性非高斯问题"),
            makeNote(content: "今天中午吃了牛肉面")
        ]
        let corpus = EmbeddingEngine.corpus(for: notes)
        let hits = EmbeddingEngine.search(query: "滤波", notes: notes, corpus: corpus)
        XCTAssertFalse(hits.isEmpty, "至少该命中一条")
        XCTAssertNotEqual(hits[0].0.id, notes[2].id, "不该把吃饭那条排在第一位")
    }

    func testSemanticSearchReturnsEmptyWhenCorpusIsStale() {
        let notes = [makeNote(content: "卡尔曼滤波")]
        let corpus = EmbeddingEngine.corpus(for: notes)
        // 传一份与语料顺序不一致的 notes：宁可返回空，也不能给出张冠李戴的结果
        let stale = [makeNote(content: "完全不同的另一条")]
        XCTAssertTrue(EmbeddingEngine.search(query: "滤波", notes: stale, corpus: corpus).isEmpty)
    }

    func testSemanticSearchIgnoresBlankQuery() {
        let notes = [makeNote(content: "卡尔曼滤波")]
        let corpus = EmbeddingEngine.corpus(for: notes)
        XCTAssertTrue(EmbeddingEngine.search(query: "   ", notes: notes, corpus: corpus).isEmpty)
    }

    // MARK: - 工具

    private func makeNote(content: String,
                          title: String = "",
                          tags: [String] = [],
                          createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Note {
        Note(id: UUID(), title: title, content: content, tags: tags, createdAt: createdAt)
    }
}
