import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var router = AppRouter()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // 五个页面都常驻，只靠透明度 + 命中测试切换。
            // 用 if 分支重建页面的话，切一次标签搜索词、导航层级全丢，体验会退步。
            ZStack {
                CaptureView().modifier(TabPage(active: router.tab == .capture))
                LibraryView().modifier(TabPage(active: router.tab == .library))
                GraphView().modifier(TabPage(active: router.tab == .graph))
                ReviewView().modifier(TabPage(active: router.tab == .review))
                SettingsView().modifier(TabPage(active: router.tab == .settings))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TabBar()
            }
        }
        .environmentObject(router)
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                store.saveNow()
            }
        }
    }
}

private struct TabPage: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

// MARK: - 底部标签栏

private struct TabBar: View {
    @EnvironmentObject private var router: AppRouter
    /// 长按采集的时刻：用来把长按之后的那次抬手判定成「不是点按」
    @State private var lastLongPressAt: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            item(.library)
            item(.graph)
            captureItem
            item(.review)
            item(.settings)
        }
        .padding(.top, 6)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Theme.card)
                    .ignoresSafeArea(edges: .bottom)
                Rectangle()
                    .fill(Theme.hairline.opacity(0.45))
                    .frame(height: 0.5)
            }
        }
    }

    private func item(_ tab: AppTab) -> some View {
        let selected = router.tab == tab
        return Button {
            router.select(tab)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(width: 46, height: 26)
                Text(tab.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.inkSoft)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 中间的采集：实心圆略重一档，但选中/未选中颜色要拉开，
    /// 否则看不出当前在不在采集页
    /// 点按 = 采集页（再点一次聚焦输入框）；长按 = 直接开始语音
    private var captureItem: some View {
        let selected = router.tab == .capture
        return Button {
            // 长按刚触发过：这次抬手不算点按
            if let t = lastLongPressAt, Date().timeIntervalSince(t) < 1.2 {
                return
            }
            router.select(.capture)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(selected ? Theme.accent : Theme.inkSoft.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.inkSoft)
                }
                .frame(width: 46, height: 30)
                Text("采集")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    lastLongPressAt = Date()
                    router.openVoice()
                }
        )
    }
}
