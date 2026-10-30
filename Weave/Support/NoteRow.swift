import SwiftUI

struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: note.source.symbol)
                .scaledFont(12, weight: .semibold, relativeTo: .caption)
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
                            .scaledFont(9, relativeTo: .caption2)
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
                                .scaledFont(10, weight: .medium, relativeTo: .caption2)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text(relativeTime(note.createdAt))
                .scaledFont(10, relativeTo: .caption2)
                .foregroundStyle(Theme.inkSoft.opacity(0.8))
        }
        .contentShape(Rectangle())
        // 一行的五个元素（图标 / 标题 / 星标 / 摘要 / 标签 / 时间）对 VoiceOver 是六次停顿，
        // 合成一个元素后用一句话读完：来源、标题、是否收藏、摘要、标签、时间。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [note.source.label]
        parts.append(note.displayTitle)
        if note.isFavorite { parts.append(String(localized: "已收藏")) }
        if !note.snippet.isEmpty { parts.append(note.snippet) }
        if !note.tags.isEmpty {
            parts.append(String(localized: "标签 \(note.tags.joined(separator: "、"))"))
        }
        parts.append(relativeTime(note.createdAt))
        return parts.joined(separator: "，")
    }

    /// 相对时间交给系统格式化器，跟着语言走。
    ///
    /// 原来是手写的中文分支（刚刚 / N分前 / N时前 / N天前），英文界面下
    /// 标题都变英文了、时间还是「1天前」，一眼就看得出没做完。
    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "刚刚") }
        // 超过一个月的笔记只显示日期，相对时间会变成「5 weeks ago」这种没信息量的说法
        if interval > 30 * 86_400 {
            return Formatters.shortDate.string(from: date)
        }
        return Formatters.relative.localizedString(for: date, relativeTo: Date())
    }
}
