import UIKit

/// 图片文件仓库：图片不再以 base64 塞进 JSON，而是落在 `Documents/Images/<uuid>.jpg`。
///
/// 起因：真机实测整库 4.4 MB 里有 4.34 MB（98.5%）是同一张图 base64 出来的。
/// 每次「记下来」都要重写整份 JSON，等于每加一条笔记就往闪存写 4 MB。
/// 外置之后 JSON 只剩 67 KB 量级，写盘快了约 65 倍。
enum ImageStore {
    /// 解码后的图片缓存。详情页每次 body 都 `UIImage(data:)` 会掉帧，
    /// 尤其上下滑动列表、反复进出详情页时。
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        // 1280px 的 JPEG 解码后约 6 MB，24 张 ≈ 150 MB，压一压上限
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Images", isDirectory: true)
    }

    /// 目录按需创建。失败就返回 false，调用方退化成「只有正文」而不是崩。
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

    /// 写入图片，返回相对文件名（只存文件名，不存绝对路径 ——
    /// iOS 的 App 沙盒目录在升级/重装后会变，存绝对路径会在某次更新后全部失效）。
    static func save(_ data: Data, name: String = UUID().uuidString) -> String? {
        guard ensureDirectory() else { return nil }
        let filename = "\(name).jpg"
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// 读图，带内存缓存。缓存命中时不碰磁盘。
    static func image(for filename: String) -> UIImage? {
        let key = filename as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url(for: filename).path) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    static func exists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: filename).path)
    }

    /// 删除单张图。笔记被删、图被换掉时调。
    static func remove(_ filename: String) {
        cache.removeObject(forKey: filename as NSString)
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    /// 清空整个图片目录（wipeAll 用）
    static func removeAll() {
        cache.removeAllObjects()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for item in items {
            try? fm.removeItem(at: directory.appendingPathComponent(item))
        }
    }

    /// 备份用：把目录里所有文件读成 [文件名: 数据]。
    /// 只收当前笔记还在引用的文件，孤儿文件不该跟着备份走大。
    static func collect(referenced: Set<String>) -> [String: Data] {
        var result: [String: Data] = [:]
        for filename in referenced {
            if let data = try? Data(contentsOf: url(for: filename)) {
                result[filename] = data
            }
        }
        return result
    }

    /// 恢复用：把备份里的图片写回目录，返回写成功的文件名集合。
    @discardableResult
    static func restore(_ files: [String: Data]) -> Set<String> {
        guard ensureDirectory() else { return [] }
        var written = Set<String>()
        for (filename, data) in files {
            // 文件名来自外部备份，必须挡掉 `../` 之类的路径穿越
            guard !filename.contains("/"), !filename.contains(".."), !filename.isEmpty else { continue }
            do {
                try data.write(to: url(for: filename), options: .atomic)
                cache.removeObject(forKey: filename as NSString)
                written.insert(filename)
            } catch {
                continue
            }
        }
        return written
    }
}
