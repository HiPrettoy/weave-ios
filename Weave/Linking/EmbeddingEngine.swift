import Foundation

/// FNV-1a：跨进程稳定的哈希（Swift 的 Hasher 每次启动种子不同，绝不能用于持久化向量）
enum StableHash {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

struct CorpusIndex {
    var documentCount: Int
    var documentFrequency: [Int: Int]

    func idf(_ bucket: Int) -> Double {
        let df = Double(documentFrequency[bucket] ?? 0)
        return log((Double(documentCount) + 1.0) / (df + 1.0)) + 1.0
    }
}

/// 一次性算好的整库向量。
///
/// 分词是这个引擎里最贵的一步（逐字符扫描 + 停用词集合查找），
/// 而 IDF 又依赖整个语料 —— 所以「查询时重建一遍」等于每敲一个字就把
/// 全库重新分词一次。这个结构把两者都缓存下来，查询时只剩余弦计算。
///
/// 关键点：查询向量与笔记向量必须用**同一个** CorpusIndex 生成。
/// 旧实现在这里混用 —— 命中缓存时拿的是上次重建时的 IDF，没命中时
/// 用刚算出来的 IDF，两个向量不在同一坐标系，算出来的分数没有意义。
struct SemanticCorpus {
    var ids: [UUID]
    var frequencies: [[Int: Double]]
    var index: CorpusIndex
    var vectors: [[Float]]
}

/// 本地向量化：Hashing Trick（512 维）+ 次线性 TF + IDF + L2 归一化。
/// 这样即使没有网络、没有 API Key，也能算出「语义上的接近程度」。
enum EmbeddingEngine {
    static let dimensions = 512

    static func bucket(for token: String) -> Int {
        Int(StableHash.fnv1a(token) % UInt64(dimensions))
    }

    static func termFrequency(_ text: String) -> [Int: Double] {
        var frequency: [Int: Double] = [:]
        for token in TextTokenizer.tokens(in: text) {
            frequency[bucket(for: token), default: 0] += 1
        }
        return frequency
    }

    static func corpusIndex(from frequencies: [[Int: Double]]) -> CorpusIndex {
        var df: [Int: Int] = [:]
        for terms in frequencies {
            for bucket in terms.keys { df[bucket, default: 0] += 1 }
        }
        return CorpusIndex(documentCount: frequencies.count, documentFrequency: df)
    }

    static func vector(tf: [Int: Double], index: CorpusIndex) -> [Float] {
        var values = [Float](repeating: 0, count: dimensions)
        for (bucket, count) in tf {
            let weight = (1.0 + log(count)) * index.idf(bucket)
            values[bucket] += Float(weight)
        }
        var norm: Float = 0
        for value in values { norm += value * value }
        norm = sqrt(norm)
        if norm > 0 {
            for i in 0..<values.count { values[i] /= norm }
        }
        return values
    }

    static func vector(for text: String, index: CorpusIndex) -> [Float] {
        vector(tf: termFrequency(text), index: index)
    }

    /// 整库分词 + IDF + 归一化向量，一次算完。关联重建与语义检索共用。
    static func corpus(for notes: [Note]) -> SemanticCorpus {
        let frequencies = notes.map { termFrequency($0.indexingText) }
        let index = corpusIndex(from: frequencies)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(notes.count)
        for tf in frequencies {
            vectors.append(vector(tf: tf, index: index))
        }
        return SemanticCorpus(ids: notes.map(\.id),
                              frequencies: frequencies,
                              index: index,
                              vectors: vectors)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var sum: Double = 0
        for i in 0..<a.count { sum += Double(a[i] * b[i]) }
        return sum
    }

    /// 语义检索。corpus 必须是与 notes 对应的那一份：
    /// 行列对齐错了就会返回错笔记，所以这里按 id 校验一遍再用。
    static func search(query: String,
                       notes: [Note],
                       corpus: SemanticCorpus,
                       limit: Int = 20) -> [(Note, Double)] {
        guard !notes.isEmpty, corpus.ids.count == notes.count else { return [] }
        for (offset, note) in notes.enumerated() where corpus.ids[offset] != note.id {
            // 语料和笔记数组顺序对不上，说明缓存过期了 —— 宁可返回空，
            // 也不能拿别人的向量给出错误的检索结果。
            return []
        }

        let queryVector = self.vector(for: query, index: corpus.index)
        guard queryVector.contains(where: { $0 != 0 }) else { return [] }

        var scored: [(Note, Double)] = []
        scored.reserveCapacity(notes.count)
        for (offset, note) in notes.enumerated() {
            let score = cosine(queryVector, corpus.vectors[offset])
            if score > 0.02 { scored.append((note, score)) }
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit))
    }
}
