import Foundation

enum LLMKeys {
    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: Prefs.llmBaseURL) ?? ""
        return stored.isEmpty ? "https://api.deepseek.com" : stored
    }

    static var model: String {
        let stored = UserDefaults.standard.string(forKey: Prefs.llmModel) ?? ""
        return stored.isEmpty ? "deepseek-chat" : stored
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: Prefs.llmKey) ?? ""
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Prefs.llmEnabled) && !apiKey.isEmpty
    }

    static var config: LLMConfig {
        LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
    }
}
