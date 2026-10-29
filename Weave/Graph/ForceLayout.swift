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

        // 收尾：把整张图缩放平移到安全区内。
        // 边距 30 只保证圆点不出界，节点标签比圆点宽得多，贴边就会被裁掉。
        let insetX: CGFloat = 52
        let insetY: CGFloat = 34
        let safe = CGRect(x: insetX,
                          y: insetY,
                          width: max(20, size.width - insetX * 2),
                          height: max(20, size.height - insetY * 2))

        var minX = positions[0].x, maxX = positions[0].x
        var minY = positions[0].y, maxY = positions[0].y
        for point in positions {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let spanX = max(1, maxX - minX)
        let spanY = max(1, maxY - minY)
        let fitScale = min(1, min(safe.width / spanX, safe.height / spanY))
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        let targetX = safe.midX
        let targetY = safe.midY

        var result: [UUID: CGPoint] = [:]
        for (offset, id) in ids.enumerated() {
            let point = positions[offset]
            result[id] = CGPoint(x: targetX + (point.x - cx) * fitScale,
                                 y: targetY + (point.y - cy) * fitScale)
        }
        return result
    }
}
