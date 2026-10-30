import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var router: AppRouter

    @State private var draft = ""
    @State private var showVoice = false
    @State private var showPhoto = false
    @State private var showManual = false
    @State private var toast: String?
    @State private var selectedNoteID: UUID?
    @State private var actionNote: Note?
    @FocusState private var draftFocused: Bool

    /// 上半部（标题+输入+三入口+提示）实测高度，用来算下方还能放几条
    @State private var topBlockHeight: CGFloat = 0
    /// 页面可用高度（已扣除底部标签栏与 Home 条）
    @State private var pageHeight: CGFloat = 0

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

    private var recent: [Note] {
        // 这个区域不做成 ScrollView——iOS 16 上滚动会吞掉父视图的拖动手势，
        // 「上滑进笔记」就废了；改成按屏幕高度决定放几条。
        Array(store.sortedNotes.prefix(recentLimit))
    }

    var body: some View {
        NavigationStack {
            // 用 GeometryReader 拿到状态栏高度，让内容顶进 safe area：
            // 其他页的标题紧贴状态栏（导航栏区域被内容占满），
            // 这里如果也从 safe area 下才开始排，顶部就会空出一大条
            GeometryReader { geo in
                captureBody(in: geo)
            }
            .ignoresSafeArea(.container, edges: .top)
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
            .sheet(isPresented: $showVoice) {
                VoiceCaptureView().environmentObject(store)
            }
            .sheet(isPresented: $showPhoto) {
                PhotoCaptureView().environmentObject(store)
            }
            .sheet(isPresented: $showManual) {
                ManualCaptureView().environmentObject(store)
            }
            .confirmationDialog(actionTitle, isPresented: Binding(
                get: { actionNote != nil },
                set: { if !$0 { actionNote = nil } }
            ), titleVisibility: .visible) {
                if let note = actionNote {
                    Button(note.isFavorite ? "取消收藏" : "收藏") {
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
                        .background(Capsule().fill(Theme.ink.opacity(0.86)))
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
                showPhoto = true
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
            topBlock(in: geo)

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
    private func topBlock(in geo: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quickCapture
            if !draftFocused {
                methods
                swipeHint
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, headerTopInset(in: geo))
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

    /// 顶部内边距：让「织识」标题与状态栏文字之间留约 26pt 呼吸。
    /// 实测 inset = status-12 时字形顶部距状态栏文字 13pt，偏贴，这里补 13pt。
    private func headerTopInset(in geo: GeometryProxy) -> CGFloat {
        let status = geo.safeAreaInsets.top
        return status > 0 ? status + 1 : 47
    }

    // MARK: - 手势

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
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
                .font(.system(size: 32, weight: .bold, design: .serif))
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

    private func statPill(_ value: String, _ label: String) -> some View {
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
                            Capsule().fill(canSave ? Theme.accent : Theme.inkSoft.opacity(0.22))
                        )
                        .foregroundStyle(.white)
                }
                .disabled(!canSave)
            }
        }
        .card(padding: 13)
    }

    private func saveDraft() {
        guard canSave else { return }
        let text = draft
        draft = ""
        // 存完就收起键盘：手机上这永远是最可靠的一条退路，
        // 顺便把下面的最近列表露出来，能立刻看到刚记下的那条。
        draftFocused = false
        _ = store.add(content: text, source: .text)
        Haptics.success()
        showToast("已记下，正在建立关联")
    }

    // MARK: - 三种采集方式（语音放正中间）

    private var methods: some View {
        HStack(spacing: 10) {
            methodButton(title: "拍照", icon: "camera.viewfinder", caption: "点开即相机\nOCR 提字", tint: Theme.warm) {
                showPhoto = true
            }
            methodButton(title: "语音", icon: "waveform", caption: "说出来\n自动转文字", tint: Theme.accent) {
                showVoice = true
            }
            methodButton(title: "手记", icon: "square.and.pencil", caption: "写长一点\n再打标签", tint: Color(uiColor: .systemIndigo)) {
                showManual = true
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
                    .font(.system(size: 15, weight: .semibold))
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
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.inkSoft)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if index < recent.count - 1 {
                            Divider().opacity(0.4)
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
        showToast("已删除这条笔记")
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.22)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
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
