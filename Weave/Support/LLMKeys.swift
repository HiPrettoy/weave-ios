import Foundation

/// 内置的 OpenAI 兼容在线模型。都是同一套 /chat/completions 协议，
/// 只是各家 base URL 与模型名不同，所以用一个预设表来切。
struct LLMPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let note: String
}

enum LLMKeys {
    /// 自定义：不走预设，手填地址与模型名
    static let customID = "custom"

    static let presets: [LLMPreset] = [
        LLMPreset(id: "deepseek-chat",
                  name: "DeepSeek V3",
                  baseURL: "https://api.deepseek.com",
                  model: "deepseek-chat",
                  note: "性价比高，中文摘要够用"),
        LLMPreset(id: "deepseek-reasoner",
                  name: "DeepSeek R1",
                  baseURL: "https://api.deepseek.com",
                  model: "deepseek-reasoner",
                  note: "推理更强，速度慢一些、更贵"),
        LLMPreset(id: "qwen-plus",
                  name: "通义千问 Plus",
                  baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                  model: "qwen-plus",
                  note: "阿里云百炼，国内直连"),
        LLMPreset(id: "moonshot-v1-8k",
                  name: "Kimi 8K",
                  baseURL: "https://api.moonshot.cn/v1",
                  model: "moonshot-v1-8k",
                  note: "月之暗面，长文本友好"),
        LLMPreset(id: "glm-4-flash",
                  name: "智谱 GLM-4-Flash",
                  baseURL: "https://open.bigmodel.cn/api/paas/v4",
                  model: "glm-4-flash",
                  note: "有免费额度，适合先试"),
        LLMPreset(id: "gpt-4o-mini",
                  name: "OpenAI GPT-4o mini",
                  baseURL: "https://api.openai.com/v1",
                  model: "gpt-4o-mini",
                  note: "需要能直连 OpenAI 的网络"),
        LLMPreset(id: "local-vllm",
                  name: "本地 vLLM / Ollama",
                  baseURL: "http://192.168.1.2:11434/v1",
                  model: "qwen2.5:7b",
                  note: "改成你自己电脑的局域网 IP")
    ]

    static func preset(id: String) -> LLMPreset? {
        presets.first { $0.id == id }
    }

    /// 当前配置正好等于某个预设时返回它的 id，否则算自定义
    static func matchedPresetID(baseURL: String, model: String) -> String? {
        let normalized = normalize(baseURL)
        return presets.first {
            $0.model == model && normalize($0.baseURL) == normalized
        }?.id
    }

    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: Prefs.llmBaseURL) ?? ""
        return stored.isEmpty ? "https://api.deepseek.com" : stored
    }

    static var model: String {
        let stored = UserDefaults.standard.string(forKey: Prefs.llmModel) ?? ""
        return stored.isEmpty ? "deepseek-chat" : stored
    }

    static var apiKey: String {
        if let stored = Keychain.string(forKey: Prefs.llmKey) {
            return stored
        }
        // 从旧版本升上来时 Key 还躺在 UserDefaults 里，搬一次家并清掉明文
        let legacy = UserDefaults.standard.string(forKey: Prefs.llmKey) ?? ""
        guard !legacy.isEmpty else { return "" }
        Keychain.set(legacy, forKey: Prefs.llmKey)
        UserDefaults.standard.removeObject(forKey: Prefs.llmKey)
        return legacy
    }

    /// 写 Key 的唯一入口：空串等于删除
    static func setAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, forKey: Prefs.llmKey)
        // 顺手清掉可能残留的明文副本
        UserDefaults.standard.removeObject(forKey: Prefs.llmKey)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Prefs.llmEnabled) && !apiKey.isEmpty
    }

    static var config: LLMConfig {
        LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
    }
}
