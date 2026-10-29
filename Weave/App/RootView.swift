import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            CaptureView()
                .tabItem { Label("采集", systemImage: "square.and.pencil") }
                .tag(0)

            LibraryView()
                .tabItem { Label("笔记", systemImage: "books.vertical") }
                .tag(1)

            GraphView()
                .tabItem { Label("图谱", systemImage: "circle.hexagongrid") }
                .tag(2)

            ReviewView()
                .tabItem { Label("复习", systemImage: "clock.arrow.circlepath") }
                .tag(3)

            SettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(4)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                store.saveNow()
            }
        }
    }
}
