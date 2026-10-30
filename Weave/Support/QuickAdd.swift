import Foundation

/// 从外部链接收一条待办稿：`weave://add?text=...&tags=学习,算法&title=...`
///
/// 为什么做这个：在此之前 App 完全没办法从外面接收内容 —— 在浏览器里读到
/// 一句好话，要存下来得「打开 App › 采集 › 手记 › 粘贴 › 保存」五步。
/// 有了 URL Scheme，快捷指令、书签、其他 App 都能一句话把它递进来。
///
/// 为什么不是分享扩展：扩展要单独的 target 与签名，TrollStore 侧没法验证；
/// URL Scheme 是纯 App 内的事，一定能用。
enum QuickAdd {
    /// 解析出来的一条草稿。不直接落库 —— 先填进采集页的输入框，
    /// 让用户看一眼再按「记下来」。外部递进来的东西不该绕过确认。
    struct Draft: Equatable {
        var text: String
        var title: String
        var tags: [String]
    }

    static let scheme = "weave"

    /// 解析一个 URL。不是 `weave://add` 或者没有正文就返回 nil。
    static func parse(_ url: URL) -> Draft? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // weave://add → host 是 "add"；weave:add → host 是 nil、path 是 "add"
        let host = (url.host ?? "").lowercased()
        let pathWord = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let action = host.isEmpty ? pathWord : host
        guard action == "add" || action == "new" else { return nil }

        let items = queryItems(from: url)
        // 正文允许三种写法：text= / content= / 整个 query 就是正文
        // （快捷指令里最省事的写法是 weave://add?<一句话>，不带等号）
        var rawText = items["text"] ?? items["content"] ?? ""
        if rawText.isEmpty, let raw = url.query, !raw.contains("=") {
            rawText = raw.removingPercentEncoding ?? raw
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let title = (items["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 标签复用全局那套解析：中英文逗号、顿号、空格、# 都算分隔符
        let tags = parseTags(items["tags"] ?? "")
        return Draft(text: text, title: title, tags: tags)
    }

    /// 自己拆 query，不用 `URLComponents`：iOS 16 上它对没写 scheme 前缀的
    /// 中文百分号转义处理得更严格，快捷指令拼出来的串经常少转义一层。
    private static func queryItems(from url: URL) -> [String: String] {
        guard let raw = url.query, !raw.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            let key = String(name).removingPercentEncoding ?? String(name)
            let value = parts.count > 1
                ? String(parts[1]).removingPercentEncoding ?? String(parts[1])
                : ""
            let normalized = key.lowercased()
            // 同一个键出现两次就保留第一个，别让后面的悄悄覆盖
            if result[normalized] == nil { result[normalized] = value }
        }
        return result
    }
}
