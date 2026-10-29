import Foundation

enum Exporter {
    static func markdown(notes: [Note], links: [NoteLink]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var relatedMap: [UUID: [Note]] = [:]
        for link in links {
            for (owner, otherID) in [(link.a, link.b), (link.b, link.a)] {
                guard let other = notes.first(where: { $0.id == otherID }) else { continue }
                relatedMap[owner, default: []].append(other)
            }
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
