import SwiftUI

/// 五个主页面。顺序就是底部标签栏的摆放顺序：采集刻意放在正中间，并且是启动页。
enum AppTab: Int, CaseIterable, Identifiable {
    case library
    case graph
    case capture
    case review
    case settings

    var id: Int { rawValue }

    /// 用 String(localized:) 而不是裸字面量：标签栏这里是 `Text(tab.title)`，
    /// 参数是 String，不走 LocalizedStringKey 的自动查表。
    var title: String {
        switch self {
        case .library: return String(localized: "笔记")
        case .graph: return String(localized: "图谱")
        case .capture: return String(localized: "采集")
        case .review: return String(localized: "复习")
        case .settings: return String(localized: "设置")
        }
    }

    var symbol: String {
        switch self {
        case .library: return "book.closed"
        case .graph: return "circle.hexagongrid"
        case .capture: return "square.and.pencil"
        case .review: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// 自绘标签栏之后，系统那套「重复点当前 tab」的行为就没了，得自己做：
/// 采集页再点一次 → 输入框聚焦弹键盘；笔记页再点一次 → 进入搜索并弹键盘。
/// 这里用一个自增计数器传意图，而不是布尔值，这样连点两次也能各触发一次。
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .capture
    @Published var captureFocusTick = 0
    @Published var searchFocusTick = 0
    @Published var cameraTick = 0
    @Published var voiceTick = 0

    func select(_ target: AppTab) {
        if tab == target {
            switch target {
            case .capture:
                captureFocusTick += 1
                Haptics.tap()
            case .library:
                searchFocusTick += 1
                Haptics.tap()
            default:
                Haptics.tap()
            }
        } else {
            tab = target
            Haptics.tap()
        }
    }

    /// 首页下滑
    func openCamera() {
        tab = .capture
        cameraTick += 1
        Haptics.tap()
    }

    /// 首页上滑
    func goLibrary() {
        tab = .library
        Haptics.tap()
    }

    /// 长按采集按钮：直接开始语音
    func openVoice() {
        tab = .capture
        voiceTick += 1
        Haptics.tap()
    }
}
