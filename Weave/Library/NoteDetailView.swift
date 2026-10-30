import SwiftUI
import UIKit

struct NoteDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let noteID: UUID
    /// 调用方（图谱）手里已经有这条笔记的完整值，直接带进来做兜底。
    /// 只靠 noteID 去 store 里查，一旦查询时点不对（sheet 的 onAppear 时机）
    /// 就会渲染成「这条笔记已经不在了」。
    var initial: Note?

    @State private var draft: Note?
    @State private var tagInput = ""
    @State private var isEnriching = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    /// 防抖落库的句柄：编辑时只改本地草稿，停下 0.6 秒或离开页面才写回 store
    @State private var pendingSave: Task<Void, Never>?
    /// 进入页面时这条笔记的索引文本。离开时只有它变了才值得跑整库重算关联。
    @State private var indexingAtEntry = ""

    /// 展示用的笔记：本地草稿 → store 实时值 → 调用方带进来的快照
    private var resolved: Note? {
        draft ?? store.note(id: noteID) ?? initial
    }

    var body: some View {
        Group {
            if let note = resolved {
                content(note)
            } else {
                Text("这条笔记已经不在了")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .onAppear {
            if draft == nil {
                draft = resolved
                indexingAtEntry = resolved?.indexingText ?? ""
            }
        }
        .navigationTitle("笔记")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 主体

    private func content(_ note: Note) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                meta(note)

                if let data = note.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !note.summary.isEmpty {
                    Text(note.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft))
                }

                TextField("标题", text: binding(\.title, fallback: ""))
                    .font(.title3.weight(.semibold))

                TextEditor(text: binding(\.content, fallback: ""))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .font(.body)

                tagSection(note)
                conceptSection(note)
                relatedSection(note)
                reviewSection(note)
                actions(note)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .onDisappear {
            // 先把还在防抖窗口里的编辑落库，再决定要不要重算关联。
            // 旧实现在这里无条件 rebuildLinks()，等于每次「点开看一眼就退出」
            // 都跑一遍整库 O(n²)，而这些笔记的索引文本根本没变。
            flushPendingSave()
            store.saveNow()
            // 笔记可能刚被删掉（delete 内部已经重建过关联），这里不再重复
            guard let note = draft, store.note(id: note.id) != nil else { return }
            if note.indexingText != indexingAtEntry {
                store.rebuildLinks()
                // 重算过了就更新基线：页面再出现时不该重复付这笔钱。
                indexingAtEntry = note.indexingText
            }
        }
        .confirmationDialog("删除这条笔记？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                // 丢掉在途的防抖任务，否则它会在 delete 之后又把这条笔记写回 store。
                pendingSave?.cancel()
                pendingSave = nil
                if let note = draft { store.delete(note) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("与它相关的关联也会一起移除，且无法恢复。")
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }

    private func meta(_ note: Note) -> some View {
        HStack(spacing: 8) {
            Label(note.source.label, systemImage: note.source.symbol)
            Text("·")
            Text(dateText(note.createdAt))
            if note.updatedAt.timeIntervalSince(note.createdAt) > 60 {
                Text("· 已编辑")
            }
            Spacer()
            Button {
                store.toggleFavorite(note)
                Haptics.tap()
                draft = store.note(id: noteID) ?? initial
            } label: {
                Image(systemName: note.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(note.isFavorite ? Theme.warm : Theme.inkSoft)
            }
            .accessibilityLabel(note.isFavorite ? String(localized: "取消收藏") : String(localized: "收藏"))
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSoft)
    }

    private func tagSection(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标签")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)

            if !note.tags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
                          alignment: .leading,
                          spacing: 6) {
                    ForEach(note.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                            Button {
                                removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .scaledFont(8, weight: .bold, relativeTo: .caption2)
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            .accessibilityLabel("删除标签 \(tag)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accentSoft))
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("加标签（回车确认）", text: $tagInput)
                    .font(.subheadline)
                    .onSubmit { addTag() }
                Button("添加", action: addTag)
                    .font(.caption.weight(.semibold))
                    .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .card()
    }

    private func conceptSection(_ note: Note) -> some View {
        Group {
            if !note.concepts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("AI 提炼的概念")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkSoft)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)],
                              alignment: .leading,
                              spacing: 6) {
                        ForEach(note.concepts, id: \.self) { concept in
                            Text(concept)
                                .font(.caption2)
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.card))
                        }
                    }
                }
                .card()
            }
        }
    }

    private func relatedSection(_ note: Note) -> some View {
        let related = store.related(to: note)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自动关联")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Text("\(related.count) 条")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
            }

            if related.isEmpty {
                Text("暂时没有找到相关笔记。再多记几条，关联会自己长出来。")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            } else {
                ForEach(related.indices, id: \.self) { index in
                    let item = related[index]
                    NavigationLink {
                        NoteDetailView(noteID: item.0.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.2.symbol)
                                .scaledFont(10, weight: .semibold, relativeTo: .caption2)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.accentSoft))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.0.displayTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text("\(item.2.label) · 相似度 \(String(format: "%.2f", item.1))")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(Theme.inkSoft.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.2.label)，\(item.0.displayTitle)，相似度 \(String(format: "%.2f", item.1))")

                    if index < related.count - 1 {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .card()
    }

    private func reviewSection(_ note: Note) -> some View {
        Group {
            if let card = store.card(for: note.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("复习安排")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkSoft)
                    Text("下次复习：\(dateText(card.due))")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink)
                    Text("已复习 \(card.reps) 次 · 遗忘 \(card.lapses) 次 · 间隔 \(SRS.humanized(card.intervalDays))")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSoft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }

    private func actions(_ note: Note) -> some View {
        VStack(spacing: 10) {
            if LLMKeys.isEnabled {
                Button {
                    enrich(note)
                } label: {
                    HStack(spacing: 6) {
                        if isEnriching {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isEnriching ? String(localized: "正在提炼…") : String(localized: "用 AI 提炼摘要与概念"))
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentSoft))
                    .foregroundStyle(Theme.accent)
                }
                .disabled(isEnriching)
            }

            ShareLink(item: note.plainText) {
                Label("分享为纯文本", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                    .foregroundStyle(Theme.ink)
            }

            Button {
                confirmDelete = true
            } label: {
                Label("删除这条笔记", systemImage: "trash")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.08)))
                    .foregroundStyle(Color.red.opacity(0.85))
            }
        }
    }

    // MARK: - 绑定与操作

    private func binding<T>(_ keyPath: WritableKeyPath<Note, T>, fallback: T) -> Binding<T> {
        Binding<T>(
            get: {
                guard let current = resolved else { return fallback }
                return current[keyPath: keyPath]
            },
            set: { newValue in
                guard var current = resolved else { return }
                current[keyPath: keyPath] = newValue
                // 旧实现在这里直接 store.update()：notes 是 @Published，
                // 每敲一个字符就会让常驻的五个页面全部重算 body，
                // 而且 updatedAt 每键都跳一次，笔记在列表里上下乱窜。
                // 现在只写本地草稿，停手 0.6 秒后再整体落库一次。
                draft = current
                schedulePendingSave(current)
            }
        )
    }

    private func schedulePendingSave(_ note: Note) {
        // 取消在途的防抖任务：Task.sleep 会因取消抛出，因此旧的 update 不会执行。
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.update(note)
            pendingSave = nil
        }
    }

    /// 离开页面前把防抖窗口里还没落库的编辑立即写回
    private func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        if let note = draft { store.update(note) }
    }

    private func addTag() {
        let tags = parseTags(tagInput)
        guard !tags.isEmpty, var current = draft else { return }
        for tag in tags where !current.tags.contains(tag) {
            current.tags.append(tag)
        }
        tagInput = ""
        draft = current
        schedulePendingSave(current)
    }

    private func removeTag(_ tag: String) {
        guard var current = resolved else { return }
        current.tags.removeAll { $0 == tag }
        draft = current
        schedulePendingSave(current)
    }

    private func enrich(_ note: Note) {
        // 先把手头未落库的编辑写回，否则 AI 结果回来时会被防抖任务里那份旧草稿盖掉。
        flushPendingSave()
        isEnriching = true
        Task {
            do {
                try await store.enrich(note, config: LLMKeys.config)
                draft = store.note(id: noteID) ?? initial
                // enrich 内部已经重建过关联，同步基线，免得离开页面时再白跑一遍 O(n²)。
                indexingAtEntry = draft?.indexingText ?? ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isEnriching = false
        }
    }

    private func dateText(_ date: Date) -> String {
        // 原来每次 body 都 new 一个 DateFormatter，详情页滚动时成本很高
        Formatters.fullDate.string(from: date)
    }
}
