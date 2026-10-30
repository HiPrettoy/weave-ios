import SwiftUI

/// 采集页里的「AI 提炼」。只做三件事：给一句话概括、给核心概念、给建议标签。
/// 不改写用户原本记下的正文——转写和 OCR 出来的字是用户的原始素材，覆盖掉风险太大。
@MainActor
final class AIExtractor: ObservableObject {
    @Published var isWorking = false
    @Published var summary = ""
    @Published var concepts: [String] = []
    @Published var tags: [String] = []
    @Published var error: String?

    var hasResult: Bool {
        !summary.isEmpty || !concepts.isEmpty || !tags.isEmpty
    }

    func clear() {
        summary = ""
        concepts = []
        tags = []
        error = nil
    }

    /// 返回是否真的拿到了结果
    @discardableResult
    func run(_ raw: String) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6 else {
            error = "内容太少，多写几句再提炼"
            return false
        }
        guard LLMKeys.isEnabled else {
            error = "云端增强没打开：到「设置」里填 API Key 并打开开关"
            return false
        }

        isWorking = true
        error = nil
        defer { isWorking = false }

        do {
            let result = try await LLMEnricher.enrich(title: "",
                                                      content: text,
                                                      baseURL: LLMKeys.baseURL,
                                                      apiKey: LLMKeys.apiKey,
                                                      model: LLMKeys.model)
            summary = result.summary
            concepts = result.concepts
            tags = result.tags
            if !hasResult {
                error = "模型返回的内容解析不出来，再点一次试试"
                return false
            }
            Haptics.success()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct AIExtractPanel: View {
    @ObservedObject var extractor: AIExtractor
    /// 当前要提炼的正文（点击那一刻取到的值）
    var text: String
    /// 提炼出的标签直接追加到各页自己的标签输入框
    var onTags: ([String]) -> Void = { _ in }
    /// 传了才显示「用作标题」，手记页可以用
    var onUseSummaryAsTitle: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        let ok = await extractor.run(text)
                        if ok && !extractor.tags.isEmpty { onTags(extractor.tags) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if extractor.isWorking {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(extractor.isWorking ? "正在提炼…" : "用 AI 提炼")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(extractor.isWorking ? Theme.inkSoft.opacity(0.2) : Theme.accentSoft)
                    )
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(extractor.isWorking)

                Spacer()

                if extractor.hasResult {
                    Button("清空") {
                        extractor.clear()
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                }
            }

            Text(LLMKeys.isEnabled
                 ? "概括 / 概念 / 标签，走你在设置里选的「\(LLMKeys.model)」"
                 : "没开云端增强，到「设置」填 API Key 就能用")
                .font(.caption2)
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)

            if let error = extractor.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.85))
            }

            if !extractor.summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("概括")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.inkSoft)
                        Spacer()
                        if let onUseSummaryAsTitle {
                            Button("用作标题") { onUseSummaryAsTitle(extractor.summary) }
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(extractor.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.accentSoft.opacity(0.5))
                )
            }

            if !extractor.concepts.isEmpty {
                chipRow(title: "概念", items: extractor.concepts, tint: Theme.accent, hashed: false)
            }

            if !extractor.tags.isEmpty {
                chipRow(title: "标签", items: extractor.tags, tint: Theme.warm, hashed: true)
            }
        }
        .card()
    }

    private func chipRow(title: String, items: [String], tint: Color, hashed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
            HStack(spacing: 6) {
                ForEach(Array(items.prefix(6)), id: \.self) { item in
                    Text(hashed ? "#\(item)" : item)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tint.opacity(0.13)))
                        .foregroundStyle(tint)
                }
            }
        }
    }
}
