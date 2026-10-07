import CatVodUI
import SwiftUI

/// iOS / iPadOS 应用入口。
///
/// 说明：M0/M1 只提供可编译的最小壳；接口管理、站点列表与播放页在 M2 接入。
@main
struct YPlayerIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
