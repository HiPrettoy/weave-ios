import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var tagFilter: String?
    @State private var semanticMode = false
    @State private var semanticHits: [(Note, Double)] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case favorite = "收藏"
        case voice = "语音"
        case photo = "拍照"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                if let tagFilter {
                    HStack(spacing: 6) {
                        Text("标签筛选：")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                        Text("#\(tagFilter)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Button {
                            self.tagFilter = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.inkSoft)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
                list
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("笔记")
            .searchable(text: $search, prompt: "标题 / 正文 / 标签")
            .toolbar {
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            semanticMode.toggle()
                            runSemanticSearch()
                        } label: {
                            Label(semanticMode ? "语义中" : "语义",
                                  systemImage: semanticMode ? "sparkles" : "sparkle")
                        }
                    }
                }
            }
            .onChange(of: search) { _ in
                if semanticMode { runSemanticSearch() }
            }
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            if semanticMode && !semanticHits.isEmpty {
                Section(header: Text("语义相关度排序").font(.caption)) {
                    ForEach(semanticHits.indices, id: \.self) { index in
                        let hit = semanticHits[index]
                        NavigationLink {
                            NoteDetailView(noteID: hit.0.id)
                        } label: {
                            HStack {
                                NoteRow(note: hit.0)
                                Text(String(format: "%.2f", hit.1))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            }

            Section {
                if filtered.isEmpty {
                    Text(semanticMode ? "没有命中的笔记" : "没有匹配的笔记")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filtered, id: \.id) { note in
                        NavigationLink {
                            NoteDetailView(noteID: note.id)
                        } label: {
                            NoteRow(note: note)
                                .padding(.vertical, 4)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                store.toggleFavorite(note)
                                Haptics.tap()
                            } label: {
                                Label(note.isFavorite ? "取消收藏" : "收藏",
                                      systemImage: note.isFavorite ? "star.slash" : "star")
                            }
                            .tint(Theme.warm)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(note)
                                Haptics.tap()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            // App 全局 tint 是主题绿，不显式指定的话这里会跟着变成绿色/蓝色，
                            // 而删除在系统语义里必须是红色。
                            .tint(Color.red)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(semanticMode ? "全部笔记" : filter.rawValue)
                    Spacer()
                    Text("\(filtered.count) 条")
                }
                .font(.caption)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 筛选条

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    Button {
                        filter = item
                        Haptics.tap()
                    } label: {
                        Text(item.rawValue)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(filter == item ? Theme.accent : Theme.card)
                            )
                            .foregroundStyle(filter == item ? Color.white : Theme.ink)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(allTags.prefix(8), id: \.self) { tag in
                    Button {
                        tagFilter = (tagFilter == tag) ? nil : tag
                    } label: {
                        Text("#\(tag)")
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(tagFilter == tag ? Theme.warm : Theme.card)
                            )
                            .foregroundStyle(tagFilter == tag ? Color.white : Theme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var allTags: [String] {
        var counter: [String: Int] = [:]
        for note in store.notes {
            for tag in note.tags { counter[tag, default: 0] += 1 }
        }
        return counter.sorted { $0.value > $1.value }.map { $0.key }
    }

    private var filtered: [Note] {
        var result = store.sortedNotes
        switch filter {
        case .all: break
        case .favorite: result = result.filter { $0.isFavorite }
        case .voice: result = result.filter { $0.source == .voice }
        case .photo: result = result.filter { $0.source == .photo }
        }

        if let tagFilter {
            result = result.filter { $0.tags.contains(tagFilter) }
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !semanticMode else { return result }
        return result.filter { note in
            note.title.localizedCaseInsensitiveContains(query)
                || note.content.localizedCaseInsensitiveContains(query)
                || note.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || note.concepts.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func runSemanticSearch() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard semanticMode, !query.isEmpty else {
            semanticHits = []
            return
        }
        semanticHits = store.semanticSearch(query, limit: 10)
    }
}
