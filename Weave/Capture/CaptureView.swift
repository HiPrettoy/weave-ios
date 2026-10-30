import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: AppRouter

    @State private var draft = ""
    /// 快记时用标签芯片挑中的标签
    @State private var draftTags: [String] = []
    /// 三个采集面板共用一个 item 型 sheet。
    /// 原来挂了三个 .sheet(isPresented:) 在同一个节点上，SwiftUI 只会保留最后一个，
    /// 别的情形下则出现「点了没反应」——同一节点只能有一个 presentation 生效。
    @State private var activeSheet: CaptureSheet?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var selectedNoteID: UUID?
    @State private var actionNote: Note?
    @FocusState private var draftFocused: Bool

    enum CaptureSheet: String, Identifiable {
        case voice, photo, manual
        var id: String { rawValue }
    }

    /// 上半部（标题+输入+三入口+提示）实测高度，用来算下方还能放几条
    @State private var topBlockHeight: CGFloat = 0
    /// 页面可用高度（已扣除底部标签栏与 Home 条）
    @State private var pageHeight: CGFloat = 0
    /// 常用标签的缓存壳（引用类型，改它不会触发整页重算）
    @State private var cache = TagUsageCacheBox()

    /// 每条笔记行的估算高度（实际 70~100，取保守值，避免最后一行被裁）
    private let rowHeight: CGFloat = 78

    /// 最近列表放几条：按剩余空间自适应，高屏多放几条，不留大片空白
    private var recentLimit: Int {
        guard !store.sortedNotes.isEmpty else { return 3 }
        // 可用高度 = 页面高 - 上半部 - 列表标题行 - 列表内外边距
        let available = pageHeight - topBlockHeight - 40 - 32
        let fits = Int(available / rowHeight)
        return max(3, min(8, fits))
    }

    /// 已用过的标签，按使用次数从多到少排（常用的排前面）。
    /// 这个列表在输入框有内容时每敲一个字都会被读一次，
    /// 原来是每次访问都遍历全库 tags 建字典再排序，输入长文时明显掉帧。
    /// 现在按 notes 的内容指纹缓存，笔记没变就直接复用。
    private var popularTags: [TagUsage] {
        let key = tagCacheKey
        if let cached = cache.tags, cached.key == key {
            return cached.items
        }
        var counts: [String: Int] = [:]
        for note in store.notes {
            for t in note.tags where !t.isEmpty {
                counts[t, default: 0] += 1
            }
        }
        let items = counts
            .map { TagUsage(tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag < rhs.tag
            }
        cache.tags = TagCache(key: key, items: items)
        return items
    }

    /// 只哈希 id 与 updatedAt：比重新统计一遍标签便宜一个数量级
    private var tagCacheKey: Int {
        var hasher = Hasher()
        hasher.combine(store.notes.count)
        for note in store.notes {
            hasher.combine(note.id)
            hasher.combine(note.updatedAt)
        }
        return hasher.finalize()
    }

    private var recent: [Note] {
        // 这个区域不做成 ScrollView——iOS 16 上滚动会吞掉父视图的拖动手势，
        // 「上滑进笔记」就废了；改成按屏幕高度决定放几条。
        Array(store.sortedNotes.prefix(recentLimit))
    }

    var body: some View {
        NavigationStack {
            // GeometryReader 只用来量页面高度（决定最近笔记显示几条），
            // 不再忽略顶部安全区 —— 忽略之后 geo.safeAreaInsets.top 恒为 0，
            // 只能靠手写兜底值，灵动岛与老机型都对不上。
            GeometryReader { geo in
                captureBody(in: geo)
            }
            .onPreferenceChange(TopBlockHeightKey.self) { newValue in
                topBlockHeight = newValue
            }
            .animation(.easeInOut(duration: 0.2), value: draftFocused)
            .background(Theme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") { draftFocused = false }
                        .font(.subheadline.weight(.medium))
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedNoteID != nil },
                set: { if !$0 { selectedNoteID = nil } }
            )) {
                if let id = selectedNoteID {
                    NoteDetailView(noteID: id)
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .voice:
                    VoiceCaptureView().environmentObject(store)
                case .photo:
                    PhotoCaptureView().environmentObject(store)
                case .manual:
                    ManualCaptureView().environmentObject(store)
                }
            }
            .confirmationDialog(actionTitle, isPresented: Binding(
                get: { actionNote != nil },
                set: { if !$0 { actionNote = nil } }
            ), titleVisibility: .visible) {
                if let note = actionNote {
                    Button(note.isFavorite ? String(localized: "取消收藏") : String(localized: "收藏")) {
                        store.toggleFavorite(note)
                        Haptics.tap()
                        actionNote = nil
                    }
                    Button("删除这条笔记", role: .destructive) {
                        delete(note)
                        actionNote = nil
                    }
                }
                Button("取消", role: .cancel) { actionNote = nil }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.scrim))
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // 已经在采集页时再点一次「采集」：直接给输入框焦点、弹键盘
            .onChange(of: router.captureFocusTick) { _ in
                draftFocused = true
            }
            // 首页下滑：直接进相机
            .onChange(of: router.cameraTick) { _ in
                draftFocused = false
                activeSheet = .photo
            }
            // 长按底部采集：直接进语音
            .onChange(of: router.voiceTick) { _ in
                draftFocused = false
                activeSheet = .voice
            }
            .onChange(of: router.tab) { newValue in
                if newValue != .capture { draftFocused = false }
            }
        }
    }

    // MARK: - 页面骨架

    /// 拆成独立函数，避免 body 的类型检查复杂到编译超时
    private func captureBody(in geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topBlock

            // 键盘弹起时把下半部收起来，避免小屏机型上固定区域被顶出屏幕。
            // 这里刻意不用 ScrollView：滚动手势会吞掉上滑进笔记的手势。
            if draftFocused {
                Spacer(minLength: 0)
            } else {
                recentSection
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
            }

            Spacer(minLength: 0)
        }
        // 上滑/下滑手势挂在整页（含「最近记下的」列表）：
        // 用 simultaneousGesture，和列表自身滚动、行点击都不冲突
        .simultaneousGesture(swipe)
        .onAppear { pageHeight = geo.size.height }
        .onChange(of: geo.size.height) { newValue in
            pageHeight = newValue
        }
    }

    /// 上半部：标题 + 输入框 + 三入口 + 提示（固定不滚动）
    private var topBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quickCapture
            if !draftFocused {
                methods
                swipeHint
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, headerTopInset)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        // 量出上半部实际高度，供下面算能放几条笔记
        .background(
            GeometryReader { p in
                Color.clear.preference(key: TopBlockHeightKey.self, value: p.size.height)
            }
        )
    }

    // MARK: - 沉浸式顶部

    /// 顶部内边距。
    ///
    /// 原来这里靠 `.ignoresSafeArea(edges: .top)` + 手写兜底值 47 来贴状态栏：
    /// 视图一旦忽略安全区，geo.safeAreaInsets.top 就恒为 0，兜底值成了唯一分支，
    /// 灵动岛机型和带 Home 键的机型都会错位。
    /// 现在不忽略顶安全区（内容自然从状态栏下开始），只补 1pt 呼吸即可，
    /// 各机型都自动正确，也不再用 UIApplication 去问窗口。
    private let headerTopInset: CGFloat = 1

    // MARK: - 手势

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                // 键盘弹起时整页在编辑状态，滑动不该跳页：
                // 否则想选中文字/移动光标时手指一竖着走就被甩到大列表或相机去。
                guard !draftFocused else { return }
                let dy = value.translation.height
                // 只认明确的竖动手势，横着划或者斜着划都不算
                guard abs(dy) > abs(value.translation.width) * 1.5, abs(dy) > 64 else { return }
                if dy < 0 {
                    router.goLibrary()
                } else {
                    router.openCamera()
                }
            }
    }

    private var swipeHint: some View {
        HStack(spacing: 14) {
            Label("上滑看全部笔记", systemImage: "arrow.up")
            Label("下滑直接拍照", systemImage: "arrow.down")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(Theme.inkSoft.opacity(0.9))
        .padding(.top, -4)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("织识")
                .scaledFont(32, weight: .bold, design: .serif, relativeTo: .largeTitle)
                .foregroundStyle(Theme.ink)
            Text("把碎片记下来，让它们自己连成网")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            HStack(spacing: 10) {
                statPill("\(store.notes.count)", "条笔记")
                statPill("\(store.links.count)", "条关联")
                statPill("\(store.notes.filter { $0.source == .voice }.count)", "语音")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 顶部只留 safe area，不再额外加内边距，消掉标题上方的空白
    }

    private func statPill(_ value: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            Text(label).font(.footnote).foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.accentSoft))
    }

    // MARK: - 快速输入

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var quickCapture: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("现在想到什么？一句话也行", text: $draft, axis: .vertical)
                .focused($draftFocused)
                .lineLimit(2...6)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .submitLabel(.done)
                .onSubmit(saveDraft)

            HStack {
                Text("保存后会自动找关联")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button(action: saveDraft) {
                    Label("记下来", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(canSave ? Theme.accentFill : Theme.inkSoft.opacity(0.22))
                        )
                        .foregroundStyle(.white)
                }
                .disabled(!canSave)
            }

            if !draftTags.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tagPicker
            }
        }
        .card(padding: 13)
    }

    /// 常用标签：已选中的排前面（实心），其余按使用次数排（描边 + 次数）
    private var tagPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .scaledFont(10, relativeTo: .caption2)
                Text("标签")
                    .font(.caption2)
                Spacer()
                if !draftTags.isEmpty {
                    Text("\(draftTags.count) 个已选")
                        .font(.caption2)
                }
            }
            .foregroundStyle(Theme.inkSoft)

            if popularTags.isEmpty {
                Text("还没有用过的标签，记下的笔记会自动带标签")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft.opacity(0.85))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(popularTags) { item in
                            tagChip(item.tag, count: item.count)
                        }
                    }
                    .padding(.vertical, 1)
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private func tagChip(_ tag: String, count: Int) -> some View {
        let picked = draftTags.contains(tag)
        return Button {
            toggleTag(tag)
        } label: {
            HStack(spacing: 3) {
                Text(tag)
                    .font(.caption)
                if count >= 2 && !picked {
                    // 用过两次以上算「常用」，标个次数
                    Text("\(count)")
                        .scaledFont(9, weight: .semibold, relativeTo: .caption2)
                        .opacity(0.75)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(picked ? Theme.accentFill : Theme.inkSoft.opacity(0.12)))
            .foregroundStyle(picked ? Color.white : Theme.ink)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleTag(_ tag: String) {
        if let idx = draftTags.firstIndex(of: tag) {
            draftTags.remove(at: idx)
        } else {
            draftTags.append(tag)
        }
        Haptics.tap()
    }

    private func saveDraft() {
        guard canSave else { return }
        let text = draft
        let tags = draftTags
        draft = ""
        draftTags = []
        // 存完就收起键盘：手机上这永远是最可靠的一条退路，
        // 顺便把下面的最近列表露出来，能立刻看到刚记下的那条。
        draftFocused = false
        // add 会校验内容，失败时返回 nil。原来直接丢返回值再无条件弹「已记下」，
        // 用户会以为存住了、其实什么也没留下。
        guard store.add(content: text, tags: tags, source: .text) != nil else {
            draft = text
            draftTags = tags
            Haptics.warning()
            showToast(String(localized: "这条没存下，内容已经放回输入框"))
            return
        }
        Haptics.success()
        // toast 是 Text(String) 而不是字面量，不走 LocalizedStringKey 查表，得显式取词
        showToast(tags.isEmpty
                  ? String(localized: "已记下，正在建立关联")
                  : String(localized: "已记下（\(tags.count) 个标签），正在建立关联"))
    }

    // MARK: - 三种采集方式（语音放正中间）

    private var methods: some View {
        HStack(spacing: 10) {
            methodButton(title: String(localized: "拍照"),
                         icon: "camera.viewfinder",
                         caption: String(localized: "点开即相机\nOCR 提字"),
                         tint: Theme.warm) {
                activeSheet = .photo
            }
            methodButton(title: String(localized: "语音"),
                         icon: "waveform",
                         caption: String(localized: "说出来\n自动转文字"),
                         tint: Theme.accent) {
                activeSheet = .voice
            }
            methodButton(title: String(localized: "手记"),
                         icon: "square.and.pencil",
                         caption: String(localized: "写长一点\n再打标签"),
                         tint: Color(uiColor: .systemIndigo)) {
                activeSheet = .manual
            }
        }
    }

    private func methodButton(title: String,
                              icon: String,
                              caption: String,
                              tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: icon)
                    .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(tint.opacity(0.13)))
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.leading)
                    // 页面整体高度吃紧时 SwiftUI 会把两行说明压成一行加省略号，
                    // 钉死纵向尺寸后它就只能去压缩下面的列表
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近记下的")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !store.notes.isEmpty {
                    // 「查看全部」放在标题行右侧：列表底部没有多余空间放整行入口
                    Button {
                        router.goLibrary()
                    } label: {
                        HStack(spacing: 3) {
                            Text("全部 \(store.notes.count) 条")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.accentSoft))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if recent.isEmpty {
                Text("还没有笔记。上面随便写一句，或者按一下语音。")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, note in
                        HStack(spacing: 6) {
                            // 行主体是按钮：点击进详情
                            Button {
                                selectedNoteID = note.id
                            } label: {
                                NoteRow(note: note)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // 右侧显式的「⋯」：收藏 / 删除，不依赖左滑或长按
                            Button {
                                actionNote = note
                            } label: {
                                Image(systemName: "ellipsis")
                                    .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                                    .foregroundStyle(Theme.inkSoft)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("更多操作")
                            .accessibilityHint("收藏或删除这条笔记")

                            if index < recent.count - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card)
                )
            }
        }
    }

    private var actionTitle: String {
        guard let note = actionNote else { return "" }
        return note.displayTitle
    }

    private func delete(_ note: Note) {
        store.delete(note)
        showToast(String(localized: "已删除这条笔记"))
    }

    private func showToast(_ message: String) {
        // 每次都取消上一个计时，否则连续保存时先前的计时会提前把新提示抹掉
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.22)) { toast = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
    }
}

// MARK: - 测量

/// 把上半部的实际高度传给父级，用于计算下方还能放几条笔记
private struct TopBlockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 标签使用统计：用于把「常用标签」按次数排序
private struct TagUsage: Identifiable {
    let tag: String
    let count: Int
    var id: String { tag }
}

/// 常用标签的缓存：把「上一次算出来的结果 + 当时的指纹」放在引用类型里，
/// 这样更新缓存不会触发 Observation 的整页重算
private struct TagCache {
    let key: Int
    let items: [TagUsage]
}

private final class TagUsageCacheBox {
    var tags: TagCache?
}
