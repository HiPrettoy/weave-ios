import SwiftUI

/// 首页的「最近记下的」是自绘卡片而不是 List，拿不到系统的 swipeActions，
/// 所以这里自己实现：左滑露出红色删除按钮，点一下确认删除；竖向拖动仍然交给外层滚动。
struct SwipeDeleteRow<Content: View>: View {
    private let onTap: () -> Void
    private let onDelete: () -> Void
    private let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var open = false
    @State private var tracking = false

    private let actionWidth: CGFloat = 82

    init(onTap: @escaping () -> Void,
         onDelete: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.onTap = onTap
        self.onDelete = onDelete
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                Haptics.success()
                close()
                onDelete()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                    Text("删除")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(open || offset < -2 ? 1 : 0)
            .allowsHitTesting(open || offset < -2)

            // 这里刻意不用 Button：Button 会抢走拖动，导致左滑根本不触发。
            // 用 onTapGesture + contentShape 代替，点按和横向拖动可以共存。
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if open {
                        close()
                    } else {
                        onTap()
                    }
                }
                .contextMenu {
                    Button {
                        onDelete()
                    } label: {
                        Label("删除这条笔记", systemImage: "trash")
                    }
                }
                .background(Theme.card)
                .offset(x: offset)
                // 用 simultaneousGesture 而不是 highPriorityGesture：外层还有个竖向 ScrollView，
                // 抢手势会让首页滚不动。这里只在自己判定为横向拖动时才改 offset。
                .simultaneousGesture(horizontalDrag)
        }
        .clipped()
    }

    /// 只有「横向位移大于纵向」时才接管，纵向留给外层 ScrollView。
    /// tracking 记录这一次拖动是不是我们接管的，避免竖滑回弹时把手势算成半开。
    private var horizontalDrag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                tracking = true
                let base: CGFloat = open ? -actionWidth : 0
                offset = min(0, max(-actionWidth, base + value.translation.width))
            }
            .onEnded { value in
                guard tracking else { return }
                let base: CGFloat = open ? -actionWidth : 0
                let projected = base + value.translation.width
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    open = projected < -actionWidth * 0.55
                    offset = open ? -actionWidth : 0
                }
                Haptics.tap()
                tracking = false
            }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            open = false
            offset = 0
        }
    }
}
