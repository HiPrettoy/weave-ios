import SwiftUI

/// 从接口实际拉一遍可用模型，让用户自己挑，而不是由 App 写死。
struct ModelPickerView: View {
    var baseURL: String
    var apiKey: String
    @Binding var selected: String

    @Environment(\.dismiss) private var dismiss

    @State private var models: [String] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var errorText: String?
    @State private var search = ""
    @State private var manual = ""

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return models }
        return models.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        List {
            if loading && models.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在向 \(hostText) 请求模型列表…")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }
            }

            if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Label("没能取到模型列表", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.red.opacity(0.85))
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("可以检查接口地址与 API Key，或者直接手填模型名。")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 4)
            }

            if !models.isEmpty {
                Section {
                    ForEach(filtered, id: \.self) { model in
                        Button {
                            selected = model
                            Haptics.tap()
                            dismiss()
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if model == selected {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("可用模型 \(filtered.count) / \(models.count)")
                } footer: {
                    Text("列表来自 \(hostText) 的 /models 接口。")
                }
            }

            Section {
                TextField("手动输入模型名", text: $manual)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.subheadline.monospaced())
                Button {
                    let name = manual.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    selected = name
                    Haptics.success()
                    dismiss()
                } label: {
                    Label("使用这个模型名", systemImage: "arrow.right.circle")
                }
                .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("列表里没有？")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "搜索模型名")
        .navigationTitle("选择模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load(force: true) }
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Label("重新获取", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(loading)
            }
        }
        .task {
            if !loaded { await load(force: false) }
        }
    }

    private var hostText: String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host else { return "这个地址" }
        return host
    }

    @MainActor
    private func load(force: Bool) async {
        if loading { return }
        if loaded && !force { return }
        loading = true
        errorText = nil
        do {
            let list = try await LLMEnricher.fetchModels(baseURL: baseURL, apiKey: apiKey)
            models = list
            loaded = true
            errorText = nil
            if list.count == 1 && selected.isEmpty { selected = list[0] }
        } catch {
            models = []
            errorText = "\(error.localizedDescription)"
        }
        loading = false
    }
}
