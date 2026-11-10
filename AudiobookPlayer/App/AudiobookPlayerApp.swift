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
        }
    }
}
