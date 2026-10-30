import Foundation

/// 自动关联：语义相似度 + 标签重合 + 时间邻近，三者加权。
/// 每次重建都会顺带刷新每条笔记的向量，所以笔记一改，关联立即跟上。
///
/// 性能：原实现是 n² 次余弦（每条比全库、每对比 512 维），1000 条要算
/// 5~10 秒并且卡在主线程。这里改成「先用倒排索引挑出候选对，再只对候选算分」：
/// 每条笔记取权重最高的若干个哈希桶，只有共享桶的笔记才可能成为候选。
/// 结果是 O(n · 桶大小) 而不是 O(n²)，同时把标签 Set 和向量范数提到循环外。
enum AutoLinker {
    struct Result {
        var notes: [Note]
        var links: [NoteLink]
        /// 本次使用的语料（分词 + IDF + 向量）。语义检索必须用同一份，
        /// 否则查询向量和已存向量不在同一个坐标系里，算出来的相似度没有意义。
        var corpus: SemanticCorpus?
    }

    /// 每条笔记参与候选匹配的高权重桶数量。
    /// 取 16：对 512 维、几十个词的短笔记，通常能覆盖主要语义；
    /// 再大候选集涨得快，收益不明显。
    private static let probeBuckets = 16

    private struct Candidate {
        let other: Int
        let score: Double
        let kind: LinkKind
    }

    static func build(notes source: [Note],
                      threshold: Double,
                      maxPerNote: Int) -> Result {
        guard source.count > 1 else {
            return Result(notes: source, links: [], corpus: nil)
        }

        var notes = source
        let corpus = EmbeddingEngine.corpus(for: notes)
        let frequencies = corpus.frequencies
        let vectors = corpus.vectors
        // 空词频的笔记（只存了图、没有可索引文字）不参与关联，
        // 否则它会靠时间邻近硬连出一堆假关联。
        let indexable = frequencies.map { !$0.isEmpty }

        // 向量跟着笔记一起写回：下次启动可以直接用，不必重新分词。
        // 不可索引的笔记显式清空而不是写 512 个 0：空数组的语义是「还没有向量」，
        // 全零向量会被误当成「算过了」；而内容被删空的笔记如果保留旧向量，
        // 语义检索会拿一段已经不存在的文本去打分。
        for offset in 0..<notes.count {
            notes[offset].embedding = indexable[offset] ? vectors[offset] : []
        }

        // 标签集合只在循环外算一次。原来每对笔记都要重建两个 Set，
        // n=1000 时这是上百万次不必要的分配。
        let tagSets: [Set<String>] = notes.map { note in
            Set(note.tags.map { $0.lowercased() })
        }
        let createdAt: [Date] = notes.map(\.createdAt)

        // MARK: 候选生成
        // bucket -> 该桶里权重最高的若干笔记。限制每桶容量，避免个别高频桶
        // （比如到处都是的「的」「the」留下的桶）把候选集撑爆。
        let bucketCap = max(8, min(64, notes.count / 4 + 8))
        var postings: [Int: [Int]] = [:]
        for offset in 0..<notes.count where indexable[offset] {
            for bucket in topBuckets(of: vectors[offset], count: probeBuckets) {
                var list = postings[bucket, default: []]
                if list.count < bucketCap { list.append(offset) }
                postings[bucket] = list
            }
        }

        var pairKeys = Set<UInt64>()
        var candidatePairs: [(Int, Int)] = []

        func consider(_ a: Int, _ b: Int) {
            let low = min(a, b), high = max(a, b)
            let key = (UInt64(low) << 32) | UInt64(high)
            guard pairKeys.insert(key).inserted else { return }
            candidatePairs.append((low, high))
        }

        // 按桶号排序再遍历：字典的 values 顺序每次运行都不一样，
        // 候选对的产生顺序就会漂移，打分相同时连出来的边也跟着变 ——
        // 同一份笔记重算两次得到不同关联，这在保存到磁盘后是能看到的。
        for bucket in postings.keys.sorted() {
            let list = postings[bucket] ?? []
            guard list.count > 1 else { continue }
            for i in 0..<(list.count - 1) {
                for j in (i + 1)..<list.count {
                    consider(list[i], list[j])
                }
            }
        }

        // 标签完全相等但语义桶没撞上的笔记也要连：标签是用户亲手打的，
        // 比哈希碰撞更可信，不能让候选剪枝把它们漏掉。
        var byTag: [String: [Int]] = [:]
        for offset in 0..<notes.count {
            for tag in tagSets[offset] {
                byTag[tag, default: []].append(offset)
            }
        }
        for tag in byTag.keys.sorted() {
            let list = byTag[tag] ?? []
            guard list.count > 1 else { continue }
            for i in 0..<(list.count - 1) {
                for j in (i + 1)..<list.count {
                    consider(list[i], list[j])
                }
            }
        }

        // MARK: 打分（每对只算一次，两个方向都计入）
        var perNote: [[Candidate]] = Array(repeating: [], count: notes.count)

        for (left, right) in candidatePairs {
            guard indexable[left], indexable[right] else { continue }
            let similarity = EmbeddingEngine.cosine(vectors[left], vectors[right])
            let tagOverlap = jaccard(tagSets[left], tagSets[right])
            let hoursApart = abs(createdAt[left].timeIntervalSince(createdAt[right])) / 3600.0
            let timeProximity = max(0.0, 1.0 - hoursApart / 72.0)
            let score = 0.68 * similarity + 0.22 * tagOverlap + 0.10 * timeProximity

            // 只靠"同一时段记的"连起来算不上关联，至少要有字面或标签重合
            guard similarity >= 0.10 || tagOverlap > 0 else { continue }
            guard score >= threshold || similarity >= 0.34 else { continue }

            let kind: LinkKind
            if tagOverlap > 0 {
                kind = .tag
            } else if similarity >= 0.20 {
                kind = .semantic
            } else {
                kind = .temporal
            }
            perNote[left].append(Candidate(other: right, score: score, kind: kind))
            perNote[right].append(Candidate(other: left, score: score, kind: kind))
        }

        // 每条笔记各自从高到低认领，直到自己的配额用完。
        // 原实现只从 i 侧单向出边再全局去重，排在前面的笔记能占满配额，
        // 后面的笔记几乎连不到东西 —— 同样两条笔记，谁先入库谁说了算。
        //
        // 现在两个方向都记账，并且**对两端分别限流**：光看「从本笔记取前 N 条」
        // 是不够的，A 认领 B、B 又认领 C 时 B 的度数会变成 2N，
        // 而界面上写的是「每条最多关联 N 条」。
        var degree: [Int] = Array(repeating: 0, count: notes.count)
        var seen = Set<String>()
        var links: [NoteLink] = []
        for offset in 0..<notes.count where degree[offset] < maxPerNote {
            var row = perNote[offset]
            guard !row.isEmpty else { continue }
            row.sort { $0.score > $1.score }
            for candidate in row {
                if degree[offset] >= maxPerNote { break }
                guard degree[candidate.other] < maxPerNote else { continue }
                let key = NoteLink.pairKey(notes[offset].id, notes[candidate.other].id)
                guard seen.insert(key).inserted else { continue }
                links.append(NoteLink(a: notes[offset].id,
                                      b: notes[candidate.other].id,
                                      score: candidate.score,
                                      kind: candidate.kind))
                degree[offset] += 1
                degree[candidate.other] += 1
            }
        }

        return Result(notes: notes, links: links, corpus: corpus)
    }

    /// 取权重最高的若干个桶，用来做倒排候选。权重相同按桶号排，保证结果稳定。
    private static func topBuckets(of vector: [Float], count: Int) -> [Int] {
        guard vector.count > count else {
            return vector.indices.filter { vector[$0] != 0 }
        }
        let limit = min(count, vector.count)
        var chosen: [(Int, Float)] = []
        chosen.reserveCapacity(limit + 1)
        for (bucket, weight) in vector.enumerated() where weight != 0 {
            if chosen.count < limit {
                chosen.append((bucket, weight))
                if chosen.count == limit { chosen.sort { $0.1 > $1.1 } }
            } else if let last = chosen.last, weight > last.1 {
                chosen[chosen.count - 1] = (bucket, weight)
                chosen.sort { $0.1 > $1.1 }
            }
        }
        return chosen.map(\.0)
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }
}
