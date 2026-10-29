import Foundation

/// 可选的云端增强：任何 OpenAI 兼容接口（DeepSeek / OpenAI / 本地 vLLM）都能用。
/// 只有在设置里填了 Key 并打开开关时才会被调用，否则一切都在端上完成。
enum LLMEnricher {
    struct Enrichment {
        var summary: String
        var concepts: [String]
        var tags: [String]
    }

    struct Payload: Decodable {
        struct Message: Decodable { let content: String? }
        struct Choice: Decodable { let message: Message? }
        let choices: [Choice]
    }

    enum EnrichError: LocalizedError {
        case missingKey
        case badURL
        case http(Int, String)
        case emptyResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "还没填 API Key"
            case .badURL: return "接口地址格式不对"
            case .http(let code, let body): return "接口返回 \(code)：\(body.prefix(120))"
            case .emptyResponse(let detail): return "无法解析返回内容：\(detail.prefix(120))"
            }
        }
    }

    static func endpoint(from rawBase: String) -> URL? {
        var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        // 已经带版本段（/v1、/paas/v4 …）就只补路径，否则补 /v1 再补路径
        let hasVersion = base.range(of: #"/v\d+$"#, options: .regularExpression) != nil
        return URL(string: base + (hasVersion ? "/chat/completions" : "/v1/chat/completions"))
    }

    struct ProbeResult {
        var latencyMs: Int
        var reply: String
    }

    // MARK: - 拉取在线可用模型

    /// 各家 /models 的路径不一样（有的在 /v1/models，有的在 /paas/v4/models，
    /// DeepSeek 的根域名也能直接 /models），所以按候选依次试，第一个成功的就用。
    static func modelEndpointCandidates(from rawBase: String) -> [URL] {
        var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        var list: [URL] = []
        func add(_ path: String) {
            if let url = URL(string: base + path), !list.contains(url) { list.append(url) }
        }
        let hasVersion = base.range(of: #"/v\d+$"#, options: .regularExpression) != nil
        if hasVersion {
            add("/models")
        } else {
            add("/v1/models")
            add("/models")
        }
        return list
    }

    /// GET /models，把返回里的模型 id 抽出来。OpenAI 兼容接口基本都回 {"data":[{"id":...}]}，
    /// 少数实现用 {"models":[{"name":...}]}，两种都兼容。
    static func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw EnrichError.missingKey }
        let candidates = modelEndpointCandidates(from: baseURL)
        guard !candidates.isEmpty else { throw EnrichError.badURL }

        var lastError: Error = EnrichError.badURL
        for url in candidates {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200...299).contains(code) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let error = EnrichError.http(code, body)
                    // 401/403 是 Key 的问题，换路径也没用，直接报出来
                    if code == 401 || code == 403 { throw error }
                    lastError = error
                    continue
                }
                let ids = parseModelIDs(data)
                if !ids.isEmpty { return ids }
                lastError = EnrichError.emptyResponse(String(data: data, encoding: .utf8) ?? "返回为空")
            } catch let error as EnrichError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func parseModelIDs(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var buckets: [[Any]] = []
        if let data = object["data"] as? [[String: Any]] { buckets.append(data) }
        if let models = object["models"] as? [[String: Any]] { buckets.append(models) }

        var ids: [String] = []
        for bucket in buckets {
            for item in bucket {
                let id = (item["id"] as? String)
                    ?? (item["name"] as? String)
                    ?? (item["model"] as? String)
                guard let id, !id.isEmpty else { continue }
                if !ids.contains(id) { ids.append(id) }
            }
            if !ids.isEmpty { break }
        }
        return ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 设置页的「测试连接」：发一条最小请求，能拿到回复才算配置可用。
    static func probe(baseURL: String, apiKey: String, model: String) async throws -> ProbeResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw EnrichError.missingKey }
        guard let url = endpoint(from: baseURL) else { throw EnrichError.badURL }

        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "deepseek-chat" : model,
            "temperature": 0,
            "max_tokens": 16,
            "messages": [["role": "user", "content": "只回复两个字：可用"]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EnrichError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data),
              let text = decoded.choices.first?.message?.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnrichError.emptyResponse(String(data: data, encoding: .utf8) ?? "返回为空")
        }
        return ProbeResult(latencyMs: latency,
                           reply: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func enrich(title: String,
                       content: String,
                       baseURL: String,
                       apiKey: String,
                       model: String) async throws -> Enrichment {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw EnrichError.missingKey }
        guard let url = endpoint(from: baseURL) else { throw EnrichError.badURL }

        let system = """
        你是一个知识整理助手。请阅读用户给出的笔记，输出严格的 JSON（不要代码块、不要解释），格式：
        {"summary":"一句话概括，不超过40字","concepts":["核心概念1","核心概念2"],"tags":["标签1","标签2"]}
        要求：concepts 3-6 个，tags 2-4 个，全部使用中文，概念要是笔记里真正出现的知识点名词。
        """

        let user = "标题：\(title.isEmpty ? "（无）" : title)\n\n正文：\n\(content)"

        let body: [String: Any] = [
            "model": model.isEmpty ? "deepseek-chat" : model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EnrichError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard let text = decoded.choices.first?.message?.content, !text.isEmpty else {
            throw EnrichError.emptyResponse("返回为空")
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Enrichment {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end,
              let data = String(cleaned[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Enrichment(summary: "", concepts: [], tags: [])
        }

        let summary = (object["summary"] as? String) ?? ""
        let concepts = (object["concepts"] as? [Any])?.compactMap { $0 as? String } ?? []
        let tags = (object["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        return Enrichment(summary: summary, concepts: concepts, tags: tags)
    }
}
