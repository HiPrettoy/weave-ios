import Foundation

/// 自动关联：语义相似度 + 标签重合 + 时间邻近，三者加权。
/// 每次重建都会顺带刷新每条笔记的向量，所以笔记一改，关联立即跟上。
enum AutoLinker {
    struct Result {
        var notes: [Note]
        var links: [NoteLink]
    }

    static func build(notes source: [Note],
                      threshold: Double,
                      maxPerNote: Int) -> Result {
        guard source.count > 1 else {
            return Result(notes: source, links: [])
        }

        var notes = source
        let frequencies = notes.map { EmbeddingEngine.termFrequency($0.indexingText) }
        let index = EmbeddingEngine.corpusIndex(from: frequencies)

        var vectors: [UUID: [Float]] = [:]
        for (offset, note) in notes.enumerated() {
            let vector = EmbeddingEngine.vector(tf: frequencies[offset], index: index)
            vectors[note.id] = vector
            notes[offset].embedding = vector
        }

        // 用 id 索引，避免 O(n²) 里反复查数组
        var byID: [UUID: Int] = [:]
        for (offset, note) in notes.enumerated() { byID[note.id] = offset }

        var seen = Set<String>()
        var links: [NoteLink] = []

        for i in 0..<notes.count {
            let left = notes[i]
            let leftVector = vectors[left.id] ?? []
            var candidates: [(UUID, Double, LinkKind)] = []

            for j in 0..<notes.count where j != i {
                let right = notes[j]
                let similarity = EmbeddingEngine.cosine(leftVector, vectors[right.id] ?? [])
                let tagOverlap = jaccard(Set(left.tags.map { $0.lowercased() }),
                                         Set(right.tags.map { $0.lowercased() }))
                let hoursApart = abs(left.createdAt.timeIntervalSince(right.createdAt)) / 3600.0
                let timeProximity = max(0.0, 1.0 - hoursApart / 72.0)
                let score = 0.68 * similarity + 0.22 * tagOverlap + 0.10 * timeProximity

                guard score >= threshold || similarity >= 0.34 else { continue }

                let kind: LinkKind
                if tagOverlap > 0 {
                    kind = .tag
                } else if similarity >= 0.20 {
                    kind = .semantic
                } else {
                    kind = .temporal
                }
                candidates.append((right.id, score, kind))
            }

            candidates.sort { $0.1 > $1.1 }
            for candidate in candidates.prefix(maxPerNote) {
                let key = NoteLink.pairKey(left.id, candidate.0)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                links.append(NoteLink(a: left.id, b: candidate.0, score: candidate.1, kind: candidate.2))
            }
        }

        return Result(notes: notes, links: links)
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }
}
