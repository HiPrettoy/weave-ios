import Foundation

enum Exporter {
    static func markdown(notes: [Note], links: [NoteLink]) -> String {
        let formatter = Formatters.fullDate

        // 先建 id → 笔记的字典。原来是在 links × notes 的双重循环里
        // 用 first(where:) 线性查找，1000 条笔记导出要几百毫秒。
        var byID: [UUID: Note] = [:]
        byID.reserveCapacity(notes.count)
        for note in notes { byID[note.id] = note }

        var relatedMap: [UUID: [Note]] = [:]
        for link in links {
            if let other = byID[link.a] { relatedMap[link.b, default: []].append(other) }
            if let other = byID[link.b] { relatedMap[link.a, default: []].append(other) }
        }

        var output = "# 织识导出 · \(formatter.string(from: Date()))\n\n"
        output += "共 \(notes.count) 条笔记，\(links.count) 条关联。\n\n"

        for note in notes.sorted(by: { $0.createdAt > $1.createdAt }) {
            output += "## \(note.displayTitle)\n\n"
            output += "- 时间：\(formatter.string(from: note.createdAt))\n"
            output += "- 来源：\(note.source.label)\n"
            if !note.tags.isEmpty {
                output += "- 标签：\(note.tags.map { "#\($0)" }.joined(separator: " "))\n"
            }
            if !note.summary.isEmpty {
                output += "- 摘要：\(note.summary)\n"
            }
            if !note.concepts.isEmpty {
                output += "- 概念：\(note.concepts.joined(separator: "、"))\n"
            }
            output += "\n\(note.content)\n\n"

            if let related = relatedMap[note.id], !related.isEmpty {
                output += "关联："
                output += related.prefix(6).map { "[[\($0.displayTitle)]]" }.joined(separator: " ")
                output += "\n\n"
            }
            output += "---\n\n"
        }
        return output
    }

    static func writeTemporaryFile(content: String, name: String = "weave-export.md") -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
