import SwiftUI
import UIKit

enum Theme {
    /// 品牌色，也用于「彩色文字」。浅色下 #1C735F（白底 5.73:1），
    /// 深色下要提亮到 #4CAF93 才能在 #1C1C1E 上有 6.36:1。
    /// 原来写死一个 RGB，深色下只有 2.97:1，正文级文字不达标。
    static let accent = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.298, green: 0.686, blue: 0.576, alpha: 1)
            : UIColor(red: 0.11, green: 0.45, blue: 0.38, alpha: 1)
    })

    /// 承载白色文字的实心块（按钮底、选中胶囊、标签圆点）。
    /// 不能跟 accent 混用：accent 在深色下是浅绿，白字压上去只有 2.67:1。
    static let accentFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.165, green: 0.502, blue: 0.443, alpha: 1)
            : UIColor(red: 0.11, green: 0.45, blue: 0.38, alpha: 1)
    })

    static var accentSoft: Color { accent.opacity(0.12) }
    static let warm = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.66, blue: 0.38, alpha: 1)
            : UIColor(red: 0.85, green: 0.52, blue: 0.26, alpha: 1)
    })

    /// warm 的白字底色版本：warm 本身压白字只有 2.86:1，深色下更差（1.98:1）。
    static let warmFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.588, green: 0.349, blue: 0.122, alpha: 1)
            : UIColor(red: 0.541, green: 0.333, blue: 0.125, alpha: 1)
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let inkSoft = Color(uiColor: .secondaryLabel)
    static let hairline = Color(uiColor: .separator)

    /// 深色浮层底（toast）。原来用 `Theme.ink.opacity(0.86)` 压白字，
    /// 可 ink 在深色下是白色 —— 白底白字，提示直接看不见。
    static let scrim = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.24, green: 0.24, blue: 0.25, alpha: 1)
            : UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    })
}

// MARK: - 跟随系统字号的固定字号

/// 直接写 `.font(.system(size: 12))` 不会跟随「设置 → 显示与亮度 → 文字大小」，
/// 用户在辅助功能里放大字号时这几处永远不变。用它包一层就不再写死。
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// 指定基准字号，同时按 Dynamic Type 缩放。
    func scaledFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.hairline.opacity(0.35), lineWidth: 0.5)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// 把 "#学习 #算法" 或 "学习,算法" 解析成标签
func parseTags(_ raw: String) -> [String] {
    let normalized = raw
        .replacingOccurrences(of: "#", with: " ")
        .replacingOccurrences(of: "，", with: ",")
        .replacingOccurrences(of: "、", with: ",")
        .replacingOccurrences(of: " ", with: ",")
    var seen = Set<String>()
    var result: [String] = []
    for piece in normalized.split(separator: ",") {
        let tag = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !seen.contains(tag) else { continue }
        seen.insert(tag)
        result.append(tag)
    }
    return result
}

/// 把新标签并进已有的标签文本，重复的不再加。AI 提炼回来的标签走这里。
func mergeTags(existing: String, incoming: [String]) -> String {
    var merged = parseTags(existing)
    for tag in incoming {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !merged.contains(trimmed) else { continue }
        merged.append(trimmed)
    }
    return merged.prefix(12).map { "#\($0)" }.joined(separator: " ")
}
