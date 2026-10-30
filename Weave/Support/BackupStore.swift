import Foundation

/// 备份文件的落地位置：`Documents/Backups/`。
///
/// 为什么不用系统的文件选择器当唯一入口：iOS 16 的 `fileImporter` 打开的是
/// 一个远程视图，真机上合成点击落不进去（取消能点，文件网格是死的）。
/// 那意味着「从备份恢复」在部分设备上等于不可用。
///
/// 于是换个思路：Info.plist 打开 `UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`，把 `Documents` 暴露给「文件」App。
/// 用户在「我的 iPhone › 织识 › Backups」里把 `.weave` 拖进来，
/// 设置页直接把这个目录列出来，点一下就恢复 —— 全程不碰系统选择器。
enum BackupStore {
    /// 一条可恢复的备份。
    struct Item: Identifiable, Hashable {
        var name: String
        var url: URL
        var modified: Date
        var bytes: Int

        var id: String { name }

        /// 「2026-10-30 22:07」这种给人看的时刻
        var modifiedText: String {
            Formatters.fullDate.string(from: modified)
        }

        /// 「239 KB」这种给人看的大小
        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
    }

    @discardableResult
    static func ensureDirectory() -> Bool {
        let url = directory
        if FileManager.default.fileExists(atPath: url.path) { return true }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// 列出可恢复的文件。`.weave` 与 `.json` 都认（后者是旧版导出的纯 JSON 备份）。
    /// 按修改时间倒序，最新的一份排在最前面。
    static func list() -> [Item] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let items: [Item] = names.compactMap { name in
            let lower = name.lowercased()
            guard lower.hasSuffix(".weave") || lower.hasSuffix(".json") else { return nil }
            // 笔记文件本身也在 Documents 里，但不在 Backups 里，正常不会撞上；
            // 万一用户把 weave-store.json 拖进来了，就当普通 JSON 备份处理，不拦。
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Item(name: name,
                        url: url,
                        modified: values?.contentModificationDate ?? Date.distantPast,
                        bytes: values?.fileSize ?? 0)
        }
        return items.sorted { $0.modified > $1.modified }
    }

    /// 写一份备份进目录，返回它的 URL（分享面板直接用这个）。
    /// 同名文件直接覆盖 —— 时间戳精确到分钟，同一分钟内连点两次就是覆盖，合理。
    @discardableResult
    static func save(_ data: Data, name: String) throws -> URL {
        guard ensureDirectory() else { throw BackupError.unwritable }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func read(_ item: Item) throws -> Data {
        try Data(contentsOf: item.url)
    }

    static func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
    }

    /// 把外部挑来的文件复制进目录，之后就能在列表里看到。
    /// 用户的原始文件不动 —— 备份是最不该被 App 改的东西。
    @discardableResult
    static func importExternal(_ url: URL) throws -> URL {
        guard ensureDirectory() else { throw BackupError.unwritable }
        let data = try Data(contentsOf: url)
        var name = url.lastPathComponent
        if name.isEmpty { name = "weave-\(Formatters.fileStamp.string(from: Date())).weave" }
        // 重名就加个序号，别把已经躺着的那份覆盖掉
        var target = directory.appendingPathComponent(name)
        var attempt = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            target = directory.appendingPathComponent("\(base)-\(attempt)\(suffix)")
            attempt += 1
        }
        try data.write(to: target, options: .atomic)
        return target
    }
}
