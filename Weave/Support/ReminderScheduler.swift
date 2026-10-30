import Foundation
import UserNotifications

/// 复习提醒。
///
/// 为什么需要：`SRS` 会把卡片排到未来某天，`ReviewView` 也会显示「今日待复习 N」，
/// 但**没有任何东西会叫用户回来** —— 不打开 App，卡片就永远躺在 due 列表里。
/// 间隔重复的价值取决于「到点有人提醒」，这是之前产品闭环里断掉的一环。
///
/// 实现上只用一条每天重复的本地通知，而不是「每张卡片一个通知」：
/// 系统待发通知上限是 64 条，卡片一多就会被静默丢弃；而且一天响三十次只会让人关掉权限。
enum ReminderScheduler {
    private static let identifier = "weave.review.daily"

    /// 请求权限。返回是否已获授权（用户点过「不允许」就是 false，之后不再弹）。
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    /// 按当前偏好与待复习数量重排提醒。
    ///
    /// - Parameters:
    ///   - dueCount: 现在到期、还没复习的卡片数
    ///   - enabled: 用户是否开着提醒
    ///   - hour / minute: 每天几点提醒
    /// - Returns: 实际排上的是哪一天（没有待复习卡片时返回 nil，通知会被撤掉）
    @discardableResult
    static func reschedule(dueCount: Int, enabled: Bool, hour: Int, minute: Int) -> Date? {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        // 没有卡片要复习就不打扰 —— 空提醒会让人习惯性地忽略它
        guard enabled, dueCount > 0 else { return nil }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "该复习了")
        content.body = String(localized: "有 \(dueCount) 张卡片等着你，几分钟就能过完。")
        content.sound = .default

        var components = DateComponents()
        components.hour = min(max(hour, 0), 23)
        components.minute = min(max(minute, 0), 59)

        // 今天的这个点已经过了就排到明天：`UNCalendarNotificationTrigger` 配 repeats
        // 会自动滚到下一个匹配时刻，但我们要的是「最早一次」，所以自己算一下用于展示。
        let calendar = Calendar.current
        let now = Date()
        var first = calendar.date(bySettingHour: components.hour ?? 9,
                                  minute: components.minute ?? 0,
                                  second: 0,
                                  of: now) ?? now
        if first <= now {
            first = calendar.date(byAdding: .day, value: 1, to: first) ?? first
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
        return first
    }

    /// 设置页里关掉开关时立刻撤掉，不等下次重排。
    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
