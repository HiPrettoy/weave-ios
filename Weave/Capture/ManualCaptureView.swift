import SwiftUI

struct ManualCaptureView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var content = ""
    @State private var tagText = ""
    @StateObject private var ai = AIExtractor()
    @FocusState private var contentFocused: Bool

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parsed: [String] { parseTags(tagText) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("标题（可留空）", text: $title)
                        .font(.title3.weight(.semibold))
                        .padding(.vertical, 6)

                    Divider().opacity(0.4)

                    TextEditor(text: $content)
                        .focused($contentFocused)
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .font(.body)

                    Divider().opacity(0.4)

                    AIExtractPanel(extractor: ai,
                                   text: content,
                                   onTags: { incoming in
                                       tagText = mergeTags(existing: tagText, incoming: incoming)
                                   },
                                   onUseSummaryAsTitle: { summary in
                                       title = String(summary.prefix(30))
                                       Haptics.tap()
                                   })

                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("标签")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.inkSoft)
                        TextField("#学习 #算法（空格或逗号分隔）", text: $tagText)
                            .font(.subheadline)
                        if !parsed.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(parsed, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Theme.accentSoft))
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("手记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { contentFocused = true }
        }
    }

    private func save() {
        guard canSave else { return }
        _ = store.add(content: content,
                      title: title,
                      tags: parsed,
                      source: .manual,
                      summary: ai.summary,
                      concepts: ai.concepts)
        Haptics.success()
        dismiss()
    }
}
