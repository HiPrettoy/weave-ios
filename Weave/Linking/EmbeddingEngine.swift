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

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var sum: Double = 0
        for i in 0..<a.count { sum += Double(a[i] * b[i]) }
        return sum
    }

    /// 对一段查询文本做语义检索：用整库重建 IDF，保证与已存向量同一坐标系
    static func search(query: String, notes: [Note], limit: Int = 20) -> [(Note, Double)] {
        guard !notes.isEmpty else { return [] }
        let frequencies = notes.map { termFrequency($0.indexingText) }
        let index = corpusIndex(from: frequencies)
        let queryVector = vector(for: query, index: index)
        guard queryVector.contains(where: { $0 != 0 }) else { return [] }

        var scored: [(Note, Double)] = []
        for (offset, note) in notes.enumerated() {
            let stored = note.embedding
            let vector = stored.count == dimensions ? stored : vector(tf: frequencies[offset], index: index)
            let score = cosine(queryVector, vector)
            if score > 0.02 { scored.append((note, score)) }
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit))
    }
}
