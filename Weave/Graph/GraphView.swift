import SwiftUI

struct GraphView: View {
    @EnvironmentObject private var store: AppStore

    @State private var positions: [UUID: CGPoint] = [:]
    @State private var degrees: [UUID: Int] = [:]
    @State private var canvasSize: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var selectedNote: Note?
    @State private var signature = ""

    private var currentSignature: String {
        "\(store.notes.count)-\(store.links.count)"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Theme.background.ignoresSafeArea()

                    if store.notes.isEmpty {
                        emptyState
                    } else {
                        canvas
                            .contentShape(Rectangle())
                            .gesture(dragGesture(size: geo.size))
                            .simultaneousGesture(magnificationGesture)

                        VStack {
                            statsBar
                            Spacer()
                            legend
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .onAppear {
                    canvasSize = geo.size
                    relayout(size: geo.size)
                }
                .onChange(of: geo.size) { newValue in
                    canvasSize = newValue
                    relayout(size: newValue)
                }
                .onChange(of: currentSignature) { _ in
                    relayout(size: geo.size)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("知识图谱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        relayout(size: canvasSize)
                        withAnimation(.easeOut(duration: 0.25)) {
                            scale = 1
                            baseScale = 1
                            offset = .zero
                            baseOffset = .zero
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            }
            .sheet(item: $selectedNote) { note in
                NavigationStack {
                    NoteDetailView(noteID: note.id, initial: note)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { selectedNote = nil }
                            }
                        }
                }
                .environmentObject(store)
            }
        }
    }

    // MARK: - 画布

    private var canvas: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var ctx = context
            ctx.translateBy(x: center.x + offset.width, y: center.y + offset.height)
            ctx.scaleBy(x: scale, y: scale)

            // 连线
            for link in store.links {
                guard let pa = positions[link.a], let pb = positions[link.b] else { continue }
                var path = Path()
                path.move(to: CGPoint(x: pa.x - center.x, y: pa.y - center.y))
                path.addLine(to: CGPoint(x: pb.x - center.x, y: pb.y - center.y))
                let alpha = 0.10 + min(0.55, link.score)
                ctx.stroke(path,
                           with: .color(Theme.accent.opacity(alpha)),
                           lineWidth: 0.6 + CGFloat(link.score) * 1.4)
            }

            // 节点
            for note in store.notes {
                guard let point = positions[note.id] else { continue }
                let centerPoint = CGPoint(x: point.x - center.x, y: point.y - center.y)
                let degree = degrees[note.id] ?? 0
                let radius = CGFloat(5.0 + min(9.0, Double(degree) * 1.6))
                let rect = CGRect(x: centerPoint.x - radius,
                                  y: centerPoint.y - radius,
                                  width: radius * 2,
                                  height: radius * 2)

                let color = color(for: note.source)
                ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.88)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.9)), lineWidth: 1.2)

                if selectedNote?.id == note.id {
                    let ringRect = rect.insetBy(dx: -4, dy: -4)
                    ctx.stroke(Path(ellipseIn: ringRect), with: .color(Theme.warm), lineWidth: 1.6)
                }

                if degree > 0 || scale > 1.1 {
                    let label = truncated(note.displayTitle, limit: 7)
                    ctx.draw(
                        Text(label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.inkSoft),
                        at: CGPoint(x: centerPoint.x, y: centerPoint.y + radius + 8)
                    )
                }
            }
        }
    }

    private func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private func color(for source: CaptureSource) -> Color {
        switch source {
        case .text: return Theme.accent
        case .voice: return Color(uiColor: .systemBlue)
        case .photo: return Theme.warm
        case .manual: return Color(uiColor: .systemIndigo)
        }
    }

    // MARK: - 叠层

    private var statsBar: some View {
        HStack(spacing: 14) {
            statItem("\(store.notes.count)", "节点")
            statItem("\(store.links.count)", "连线")
            statItem(String(format: "%.1f", averageDegree), "平均关联")
            Spacer()
            Text(String(format: "x%.1f", scale))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card.opacity(0.92))
        )
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var averageDegree: Double {
        guard !store.notes.isEmpty else { return 0 }
        return Double(store.links.count * 2) / Double(store.notes.count)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("文字", Theme.accent)
            legendItem("语音", Color(uiColor: .systemBlue))
            legendItem("拍照", Theme.warm)
            legendItem("手记", Color(uiColor: .systemIndigo))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Theme.card.opacity(0.92))
        )
    }

    private func legendItem(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.inkSoft.opacity(0.5))
            Text("还没有节点")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text("去「采集」里记几条，图谱会自动长出来")
                .font(.footnote)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    // MARK: - 手势

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { value in
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved < 8 {
                    offset = baseOffset
                    handleTap(at: value.location, size: size)
                } else {
                    baseOffset = offset
                }
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(3.0, max(0.45, baseScale * value))
            }
            .onEnded { _ in
                baseScale = scale
            }
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        guard size.width > 0 else { return }
        let graphPoint = CGPoint(
            x: (location.x - size.width / 2 - offset.width) / scale + size.width / 2,
            y: (location.y - size.height / 2 - offset.height) / scale + size.height / 2
        )

        var hit: Note?
        var bestDistance: CGFloat = 26 / scale
        for note in store.notes {
            guard let point = positions[note.id] else { continue }
            let distance = hypot(point.x - graphPoint.x, point.y - graphPoint.y)
            if distance < bestDistance {
                bestDistance = distance
                hit = note
            }
        }

        if let hit {
            Haptics.tap()
            selectedNote = hit
        } else {
            selectedNote = nil
        }
    }

    // MARK: - 布局

    private func relayout(size: CGSize) {
        guard size.width > 10, size.height > 10, !store.notes.isEmpty else { return }
        let ids = store.notes.map { $0.id }
        let edges = store.links.map { ($0.a, $0.b) }
        positions = ForceLayout.compute(ids: ids, edges: edges, size: size)

        var counter: [UUID: Int] = [:]
        for link in store.links {
            counter[link.a, default: 0] += 1
            counter[link.b, default: 0] += 1
        }
        degrees = counter
        signature = currentSignature
    }
}
