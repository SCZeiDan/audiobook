import SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var sleepTimer: SleepTimer
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .library
    @State private var showPlayer = false

    enum Tab: Hashable {
        case library
        case settings
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                LibraryView(onOpenPlayer: { showPlayer = true })
            }
            .tabItem {
                Label("书库", systemImage: "books.vertical")
            }
            .tag(Tab.library)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if engine.currentBook != nil {
                MiniPlayerBar(onOpen: { showPlayer = true })
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(sleepTimer)
                .environmentObject(engine.clock)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background, .inactive:
                engine.persistProgress()
            default:
                break
            }
        }
        .task {
            AudioEngine.shared.restoreLastSession()
            await LibraryStore.shared.refreshMissingDurations()
            AudioEngine.shared.refreshCurrentBookFromStore()
        }
    }
}

// MARK: - 迷你播放条

struct MiniPlayerBar: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var sleepTimer: SleepTimer

    var onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                BookCoverView(book: engine.currentBook, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.currentBook?.title ?? "未在播放")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    // 只让这一行文字每秒自己刷新，迷你条其余部分不动
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    engine.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 19))
                }
                .buttonStyle(.plain)

                Button {
                    engine.toggle()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 34)
                }
                .buttonStyle(.plain)

                Button {
                    engine.skip(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 19))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            if sleepTimer.remaining != nil {
                Text(sleepTimer.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .background(.bar)
            }
        }
    }

    private var subtitle: String {
        let time = Audiobook.timeString(engine.currentTime)
        let total = Audiobook.timeString(engine.duration)
        let queue = engine.queueName.map { "· \($0)" } ?? ""
        if engine.isPlaying {
            return "\(time) / \(total)\(queue)"
        }
        return "已暂停 · \(time)\(queue)"
    }
}
