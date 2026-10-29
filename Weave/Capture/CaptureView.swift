import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var store: AppStore

    @State private var draft = ""
    @State private var showVoice = false
    @State private var showPhoto = false
    @State private var showManual = false
    @State private var toast: String?
    @State private var selectedNoteID: UUID?
    @FocusState private var draftFocused: Bool

    private var recent: [Note] {
        Array(store.sortedNotes.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    quickCapture
                    methods
                    recentSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .navigationBarHidden(true)
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
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("织识")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(Theme.ink)
            Text("把碎片记下来，让它们自己连成网")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            HStack(spacing: 10) {
                statPill("\(store.notes.count)", "条笔记")
                statPill("\(store.links.count)", "条关联")
                statPill("\(store.notes.filter { $0.source == .voice }.count)", "语音")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
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
                .lineLimit(3...8)
                .font(.body)
                .foregroundStyle(Theme.ink)

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
        .card()
    }

    private func saveDraft() {
        guard canSave else { return }
        let text = draft
        draft = ""
        draftFocused = false
        _ = store.add(content: text, source: .text)
        Haptics.success()
        showToast("已记下，正在建立关联")
    }

    // MARK: - 三种采集方式

    private var methods: some View {
        HStack(spacing: 12) {
            methodButton(title: "语音", icon: "waveform", caption: "说出来\n自动转文字", tint: Theme.accent) {
                showVoice = true
            }
            methodButton(title: "拍照", icon: "camera.viewfinder", caption: "点开即相机\nOCR 提字", tint: Theme.warm) {
                showPhoto = true
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
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(tint.opacity(0.13)))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                    Text("共 \(store.notes.count) 条 · 长按可删除")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSoft)
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
                        NoteRow(note: note)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedNoteID = note.id }
                            .contextMenu {
                                Button {
                                    store.toggleFavorite(note)
                                    Haptics.tap()
                                } label: {
                                    Label(note.isFavorite ? "取消收藏" : "收藏",
                                          systemImage: note.isFavorite ? "star.slash" : "star")
                                }
                                Button(role: .destructive) {
                                    delete(note)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
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

    private func delete(_ note: Note) {
        store.delete(note)
        showToast("已删除这条笔记")
    }

    private func showToast(_ message: String) {        withAnimation(.easeOut(duration: 0.22)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
    }
}
