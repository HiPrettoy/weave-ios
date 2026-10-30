import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var store: AppStore
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if let card = store.dueCards.first, let note = store.note(id: card.noteID) {
                    cardBody(card: card, note: note)
                } else {
                    emptyState
                }
            }
            .navigationTitle("复习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("今日待复习 \(store.dueCards.count)")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        }
    }

    // MARK: - 卡片

    private func cardBody(card: ReviewCard, note: Note) -> some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Label(note.source.label, systemImage: note.source.symbol)
                        Spacer()
                        Text("第 \(card.reps + 1) 次")
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)

                    Text(note.displayTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("先在心里复述一遍，再点「看答案」")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                        .accessibilityHidden(true)

                    if revealed {
                        Divider().opacity(0.4)

                        Text(note.content)
                            .font(.body)
                            .foregroundStyle(Theme.ink)

                        if !note.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(note.tags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Theme.accentSoft))
                                }
                            }
                        }

                        let related = store.related(to: note, limit: 3)
                        if !related.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("可以一起想起来")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.inkSoft)
                                ForEach(related.indices, id: \.self) { index in
                                    Text("· \(related[index].0.displayTitle)")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.ink)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card)
                )
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            if revealed {
                gradeButtons(card: card)
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { revealed = true }
                    Haptics.tap()
                } label: {
                    Text("看答案")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentFill))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 12)
    }

    private func gradeButtons(card: ReviewCard) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { grade in
                Button {
                    store.grade(card, grade: grade)
                    revealed = false
                    Haptics.tap()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: SRS.gradeSymbols[grade])
                            .scaledFont(14, weight: .semibold, relativeTo: .subheadline)
                        Text(SRS.grades[grade])
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(grade == 0 ? Color.red.opacity(0.10) : Theme.accentSoft)
                    )
                    .foregroundStyle(grade == 0 ? Color.red.opacity(0.85) : Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SRS.grades[grade])
                .accessibilityHint(grade == 0 ? String(localized: "间隔会重置，稍后再出现") : String(localized: "按记忆程度推进下次复习时间"))
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .scaledFont(44, weight: .light, relativeTo: .largeTitle)
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text("今天清空了")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("共 \(store.cards.count) 张卡片在排队")
                .font(.footnote)
                .foregroundStyle(Theme.inkSoft)

            if let next = store.cards.min(by: { $0.due < $1.due }), next.due > Date() {
                Text("下一张：\(relative(next.due))")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.top, 4)
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return String(localized: "现在") }
        if interval < 3600 {
            return String(localized: "\(Int(interval / 60)) 分钟后")
        }
        if interval < 86_400 {
            return String(localized: "\(Int(interval / 3600)) 小时后")
        }
        return String(localized: "\(Int(interval / 86_400)) 天后")
    }
}
