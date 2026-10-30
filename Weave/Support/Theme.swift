import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.11, green: 0.45, blue: 0.38)
    static let accentSoft = Color(red: 0.11, green: 0.45, blue: 0.38).opacity(0.12)
    static let warm = Color(red: 0.85, green: 0.52, blue: 0.26)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let inkSoft = Color(uiColor: .secondaryLabel)
    static let hairline = Color(uiColor: .separator)
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
