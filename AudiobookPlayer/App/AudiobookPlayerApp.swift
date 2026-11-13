import SwiftUI

@main
struct AudiobookPlayerApp: App {
    @ObservedObject private var engine = AudioEngine.shared
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var sleepTimer = SleepTimer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(sleepTimer)
                // 播放进度单独一个环境对象：0.25 秒一次的刷新只影响读它的视图，
                // 不会把整个书库列表拖着一起重算
                .environmentObject(engine.clock)
        }
    }
}
