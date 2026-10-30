import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: AppRouter

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var selectedTags: Set<String> = []
    @State private var tagMatchAll = false
    @State private var semanticMode = false
    @State private var semanticHits: [(Note, Double)] = []
    @FocusState private var searchFocused: Bool

    /// 过滤结果与标签云的缓存。
    /// 原来的 filtered / allTags 是计算属性，body 里被引用三次就整库排序过滤三次，
    /// 每敲一个字都要重来一遍。现在按输入指纹缓存，命中就复用。
    private final class DerivedCache {
        var key: Int = 0
        var valid = false
        var filtered: [Note] = []
        var tags: [String] = []
    }

    @State private var cache = DerivedCache()
    /// 语义搜索的防抖句柄：原来每敲一个字都同步跑一遍全库余弦，
    /// 输入长词时等于每键一次全库计算。现在停手 250ms 才真正搜。
    @State private var semanticTask: Task<Void, Never>?

    enum Filter: String, CaseIterable, Identifiable {
        case all, favorite, voice, photo, manual

        var id: String { rawValue }

        /// 筛选条上的文字。
        ///
        /// 原来把中文直接写进 rawValue，`Text(filter.rawValue)` 收到的是 String，
        /// 不会去查本地化表，切英文后这几颗胶囊还是中文。
        var title: String {
            switch self {
            case .all: return String(localized: "全部")
            case .favorite: return String(localized: "收藏")
            case .voice: return String(localized: "语音")
            case .photo: return String(localized: "拍照")
            case .manual: return String(localized: "手记")
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("笔记")
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: query) { _ in
                    if semanticMode { runSemanticSearch() }
                }
                // 已经在笔记页时再点一次「笔记」：直接进入搜索状态
                .onChange(of: router.searchFocusTick) { _ in
                    searchFocused = true
                }
                .onChange(of: router.tab) { newValue in
                    if newValue != .library { searchFocused = false }
                }
        }
    }

    private var content: some View {
        let derived = derivedSnapshot()
        return VStack(spacing: 0) {
            searchBar
            filterBar
            tagBar(tags: derived.tags)
            list(notes: derived.filtered)
        }
    }

    // MARK: - 搜索栏

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
                TextField("标题 / 正文 / 标签 / 概念", text: $query)
                    .focused($searchFocused)
                    .font(.subheadline)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.card))

            if !trimmedQuery.isEmpty {
                Button {
                    semanticMode.toggle()
                    runSemanticSearch()
                    Haptics.tap()
                } label: {
                    Image(systemName: semanticMode ? "sparkles" : "sparkle")
                        .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(semanticMode ? Color.white : Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(semanticMode ? Theme.accentFill : Theme.accentSoft))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("语义排序")
                .accessibilityValue(semanticMode ? String(localized: "已开启") : String(localized: "已关闭"))
                .accessibilityHint("打开后按文本含义而不是字面匹配排序")
            }

            if searchFocused || !query.isEmpty {
                Button("取消") {
                    query = ""
                    semanticMode = false
                    semanticTask?.cancel()
                    semanticTask = nil
                    semanticHits = []
                    searchFocused = false
                }
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 列表

    private func list(notes: [Note]) -> some View {
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
                                    .accessibilityLabel("相关度 \(String(format: "%.2f", hit.1))")
                            }
                        }
                    }
                }
            }

            Section {
                if notes.isEmpty {
                    Text(emptyMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(notes, id: \.id) { note in
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
                                Label(note.isFavorite ? String(localized: "取消收藏") : String(localized: "收藏"),
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
                    Text(semanticMode ? String(localized: "全部笔记") : filter.title)
                    Spacer()
                    Text("\(notes.count) 条")
                }
                .font(.caption)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyMessage: String {
        if !selectedTags.isEmpty { return String(localized: "没有同时命中这些标签的笔记") }
        if !trimmedQuery.isEmpty { return String(localized: "没有匹配的笔记") }
        return String(localized: "还没有笔记")
    }

    // MARK: - 来源筛选条

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    Button {
                        filter = item
                        Haptics.tap()
                    } label: {
                        Text(item.title)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(filter == item ? Theme.accentFill : Theme.card)
                            )
                            .foregroundStyle(filter == item ? Color.white : Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 标签（多选）

    private func tagBar(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                // 清除放在最前面：标签一多，横滑之后它就跑到看不见的地方去了
                if !selectedTags.isEmpty {
                    Button {
                        selectedTags.removeAll()
                        Haptics.tap()
                    } label: {
                        Label("清除 \(selectedTags.count)", systemImage: "xmark")
                            .font(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().stroke(Theme.inkSoft.opacity(0.4), lineWidth: 1))
                            .foregroundStyle(Theme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }

                if selectedTags.count >= 2 {
                    Button {
                        tagMatchAll.toggle()
                        Haptics.tap()
                    } label: {
                        Label(tagMatchAll ? String(localized: "同时满足") : String(localized: "任一匹配"),
                              systemImage: tagMatchAll ? "checkmark.circle.fill" : "circle.circle")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.inkSoft.opacity(0.12)))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(tags, id: \.self) { tag in
                    let selected = selectedTags.contains(tag)
                    Button {
                        if selected {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                        Haptics.tap()
                    } label: {
                        Text("#\(tag)")
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(selected ? Theme.warmFill : Theme.card)
                            )
                            .foregroundStyle(selected ? Color.white : Theme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 过滤与标签云（带缓存）

    /// 输入指纹：只有它变了才重算过滤与标签云。
    /// 用笔记 id + updatedAt 参与哈希，保证新增/编辑/删除都会让缓存失效，
    /// 而滚动列表、切换焦点这类纯 UI 变化不会。
    private func derivedKey() -> Int {
        var hasher = Hasher()
        hasher.combine(store.notes.count)
        for note in store.notes {
            hasher.combine(note.id)
            hasher.combine(note.updatedAt)
            hasher.combine(note.isFavorite)
        }
        hasher.combine(filter)
        hasher.combine(trimmedQuery)
        hasher.combine(tagMatchAll)
        for tag in selectedTags.sorted() { hasher.combine(tag) }
        return hasher.finalize()
    }

    private func derivedSnapshot() -> (filtered: [Note], tags: [String]) {
        let key = derivedKey()
        if cache.valid && cache.key == key {
            return (cache.filtered, cache.tags)
        }
        let notes = computeFiltered()
        let tags = computeAllTags()
        cache.key = key
        cache.valid = true
        cache.filtered = notes
        cache.tags = tags
        return (notes, tags)
    }

    private func computeAllTags() -> [String] {
        var counter: [String: Int] = [:]
        for note in store.notes {
            for tag in note.tags { counter[tag, default: 0] += 1 }
        }
        return counter.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map { $0.key }
    }

    private func computeFiltered() -> [Note] {
        var result = store.sortedNotes
        switch filter {
        case .all: break
        case .favorite: result = result.filter { $0.isFavorite }
        case .voice: result = result.filter { $0.source == .voice }
        case .photo: result = result.filter { $0.source == .photo }
        case .manual: result = result.filter { $0.source == .manual }
        }

        if !selectedTags.isEmpty {
            result = result.filter { note in
                let tags = Set(note.tags)
                return tagMatchAll ? selectedTags.isSubset(of: tags)
                                  : !selectedTags.isDisjoint(with: tags)
            }
        }

        guard !trimmedQuery.isEmpty, !semanticMode else { return result }
        return result.filter { note in
            note.title.localizedCaseInsensitiveContains(trimmedQuery)
                || note.content.localizedCaseInsensitiveContains(trimmedQuery)
                || note.tags.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
                || note.concepts.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
        }
    }

    private func runSemanticSearch() {
        guard semanticMode, !trimmedQuery.isEmpty else {
            semanticTask?.cancel()
            semanticTask = nil
            semanticHits = []
            return
        }
        let needle = trimmedQuery
        semanticTask?.cancel()
        semanticTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, semanticMode, trimmedQuery == needle else { return }
            semanticHits = store.semanticSearch(needle, limit: 10)
        }
    }
}
