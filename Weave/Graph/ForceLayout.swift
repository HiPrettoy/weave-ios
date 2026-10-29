import SwiftUI

/// Fruchterman-Reingold 力导向布局，一次算完直接出静态坐标。
/// 初始化用黄金角螺旋而不是随机数，保证同一份数据每次布局一致。
enum ForceLayout {
    static func compute(ids: [UUID], edges: [(UUID, UUID)], size: CGSize) -> [UUID: CGPoint] {
        let count = ids.count
        guard count > 0, size.width > 10, size.height > 10 else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if count == 1 { return [ids[0]: center] }

        let area = Double(size.width * size.height)
        let k = sqrt(area / Double(count))
        let radius = Double(min(size.width, size.height)) * 0.36
        let goldenAngle = 2.399963229728653

        var positions: [CGPoint] = []
        for index in 0..<count {
            let angle = Double(index) * goldenAngle
            let r = radius * sqrt(Double(index + 1) / Double(count))
            positions.append(CGPoint(x: center.x + CGFloat(cos(angle) * r),
                                     y: center.y + CGFloat(sin(angle) * r)))
        }

        var indexOf: [UUID: Int] = [:]
        for (offset, id) in ids.enumerated() { indexOf[id] = offset }

        var pairs: [(Int, Int)] = []
        for (a, b) in edges {
            guard let i = indexOf[a], let j = indexOf[b], i != j else { continue }
            pairs.append((i, j))
        }

        var temperature = Double(min(size.width, size.height)) * 0.12
        let iterations = 300

        for _ in 0..<iterations {
            var displacement = [CGPoint](repeating: .zero, count: count)

            if count > 1 {
                for i in 0..<(count - 1) {
                    for j in (i + 1)..<count {
                        let dx = Double(positions[i].x - positions[j].x)
                        let dy = Double(positions[i].y - positions[j].y)
                        let distance = max(0.01, sqrt(dx * dx + dy * dy))
                        let force = k * k / distance
                        let ux = dx / distance
                        let uy = dy / distance
                        displacement[i].x += CGFloat(ux * force)
                        displacement[i].y += CGFloat(uy * force)
                        displacement[j].x -= CGFloat(ux * force)
                        displacement[j].y -= CGFloat(uy * force)
                    }
                }
            }

            for (i, j) in pairs {
                let dx = Double(positions[i].x - positions[j].x)
                let dy = Double(positions[i].y - positions[j].y)
                let distance = max(0.01, sqrt(dx * dx + dy * dy))
                let force = distance * distance / k
                let ux = dx / distance
                let uy = dy / distance
                displacement[i].x -= CGFloat(ux * force)
                displacement[i].y -= CGFloat(uy * force)
                displacement[j].x += CGFloat(ux * force)
                displacement[j].y += CGFloat(uy * force)
            }

            let margin: CGFloat = 30
            for i in 0..<count {
                let dx = Double(displacement[i].x)
                let dy = Double(displacement[i].y)
                let length = max(0.01, sqrt(dx * dx + dy * dy))
                let step = min(length, temperature)
                var x = positions[i].x + CGFloat(dx / length * step)
                var y = positions[i].y + CGFloat(dy / length * step)
                x = min(max(x, margin), size.width - margin)
                y = min(max(y, margin), size.height - margin)
                positions[i] = CGPoint(x: x, y: y)
            }

            temperature *= 0.985
        }

        var result: [UUID: CGPoint] = [:]
        for (offset, id) in ids.enumerated() { result[id] = positions[offset] }
        return result
    }
}
