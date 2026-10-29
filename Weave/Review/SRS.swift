import Foundation

/// 轻量 SM-2：四档评分，够用且好解释。
enum SRS {
    static let grades = ["忘了", "模糊", "记得", "太简单"]
    static let gradeSymbols = ["arrow.counterclockwise", "cloud", "checkmark", "bolt"]

    static func apply(grade: Int, to card: ReviewCard) -> ReviewCard {
        var card = card
        let clamped = min(max(grade, 0), 3)
        let quality = [1, 3, 4, 5][clamped]

        if quality < 3 {
            card.reps = 0
            card.lapses += 1
            card.ease = max(1.3, card.ease - 0.2)
            card.intervalDays = 0.02   // 约 30 分钟后再问一次
        } else {
            card.reps += 1
            switch card.reps {
            case 1:
                card.intervalDays = 1
            case 2:
                card.intervalDays = 3
            default:
                let multiplier: Double = quality == 3 ? 1.2 : (quality == 5 ? 1.45 : 1.3)
                card.intervalDays = max(1, card.intervalDays * max(1.3, card.ease) * multiplier)
            }
            let delta = 0.1 - Double(5 - quality) * (0.08 + Double(5 - quality) * 0.02)
            card.ease = min(2.8, max(1.3, card.ease + delta))
        }

        card.intervalDays = min(card.intervalDays, 365)
        card.due = Date().addingTimeInterval(card.intervalDays * 86_400)
        card.lastReviewed = Date()
        return card
    }

    static func humanized(_ days: Double) -> String {
        if days <= 0 { return "现在" }
        if days < 1.0 / 24.0 { return "马上" }
        if days < 1 { return "\(Int((days * 24 * 60).rounded())) 分钟后" }
        if days < 30 { return "\(Int(days.rounded())) 天后" }
        return "\(Int((days / 30).rounded())) 个月后"
    }
}
