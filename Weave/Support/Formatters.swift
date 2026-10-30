import Foundation

/// 共享的日期格式化器。
///
/// DateFormatter 的初始化要读 locale/calendar 数据，是出了名的贵；
/// 原来 NoteRow 的每一行、详情页的每次 body 重绘、导出的每一条笔记都在 new 一个，
/// 滚动列表时这笔开销直接摊在帧时间上。这些格式是固定的，做成静态常量即可。
enum Formatters {
    /// 列表里的相对时间：刚刚 / 12 分钟前 / 3 hours ago
    ///
    /// 跟着系统语言走。原来这里写死 zh_Hans_CN，切到英文界面时只有笔记标题变了、
    /// 时间还是「1天前」，中英混排看着像没做完的本地化。
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .short
        return formatter
    }()

    /// 超过一个月的笔记只显示日期，按当前语言给格式（中「8月19日」/ 英「Aug 19」）
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// 详情页与导出用的完整时间，同样按当前语言给格式
    static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yMMMdHHmm")
        return formatter
    }()

    /// 备份文件名里的时间戳。必须用 POSIX locale，否则某些地区会输出非 ASCII 数字。
    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}
