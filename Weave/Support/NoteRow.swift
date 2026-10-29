import SwiftUI

struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: note.source.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accentSoft))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(note.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if note.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warm)
                    }
                }

                if !note.snippet.isEmpty {
                    Text(note.snippet)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(2)
                }

                if !note.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(note.tags.prefix(3)), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text(relativeTime(note.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(Theme.inkSoft.opacity(0.8))
        }
        .contentShape(Rectangle())
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分前" }
        if interval < 86_400 { return "\(Int(interval / 3600))时前" }
        let days = Int(interval / 86_400)
        if days < 30 { return "\(days)天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}
