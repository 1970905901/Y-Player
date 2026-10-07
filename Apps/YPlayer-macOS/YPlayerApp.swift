import CatVodUI
import SwiftUI

/// macOS 应用入口。
@main
struct YPlayerMacApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}
