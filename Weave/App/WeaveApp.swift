import SwiftUI

@main
struct WeaveApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .tint(Theme.accent)
                // weave://add?text=...&tags=... 从这里进来。
                // router 必须在这一层持有：`onOpenURL` 往它里面塞草稿，
                // 而采集页从环境里取同一个实例，RootView 不再自己 new。
                .onOpenURL { url in
                    guard let draft = QuickAdd.parse(url) else { return }
                    router.accept(draft)
                }
        }
    }
}
