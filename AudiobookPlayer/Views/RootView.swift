import SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var sleepTimer: SleepTimer
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .home
    @State private var showPlayer = false

    /// 对齐 Apple 播客：底部只有「主页」和「资料库」
    enum Tab: Hashable {
        case home
        case library
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView(onOpenPlayer: { showPlayer = true })
                    .miniPlayerBar(onOpen: { showPlayer = true })
            }
            .tabItem {
                Label("主页", systemImage: "house")
            }
            .tag(Tab.home)

            NavigationStack {
                LibraryView(onOpenPlayer: { showPlayer = true })
                    .miniPlayerBar(onOpen: { showPlayer = true })
            }
            .tabItem {
                Label("资料库", systemImage: "rectangle.stack")
            }
            .tag(Tab.library)
        }
        .tint(Color.accentColor)
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
            case .active:
                // 从「文件」App 往 Audio/ 里拖完切回来，立刻把新文件 / 新文件夹收进来
                store.reconcile()
                AudioEngine.shared.refreshCurrentBookFromStore()
                Task { await store.refreshMissingDurations() }
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

// MARK: - 迷你播放条（浮在 TabBar 之上）

extension View {
    /// 用 safeAreaInset 挂在每个 Tab 的内容上，才会浮在 TabBar 上方而不是被它推到屏幕底
    func miniPlayerBar(onOpen: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(onOpen: onOpen)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var sleepTimer: SleepTimer

    var onOpen: () -> Void

    var body: some View {
        if let book = engine.currentBook {
            VStack(spacing: 0) {
                // 顶部一条 2pt 进度线，播客的迷你条没有，但一眼能看出听到哪了
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    progressLine
                }

                HStack(spacing: 11) {
                    BookCoverView(book: book, size: 42)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(book.title)
                            .font(.subheadline.weight(.semibold))
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
                        engine.skip(by: 30)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("快进 30 秒")

                    Button {
                        engine.toggle()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 23, weight: .medium))
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(engine.isPlaying ? "暂停" : "播放")
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.bottom, 8)
                .padding(.top, 7)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.14), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .contain)
        }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .padding(.top, 2)
        .padding(.horizontal, 2)
    }

    private var fraction: Double {
        guard engine.duration > 0.1 else { return 0 }
        return min(max(engine.currentTime / engine.duration, 0), 1)
    }

    private var subtitle: String {
        var parts: [String] = []

        let elapsed = Audiobook.timeString(engine.currentTime)
        let total = Audiobook.timeString(engine.duration)
        if engine.isPlaying {
            parts.append("\(elapsed) / \(total)")
        } else {
            parts.append("已暂停 · \(elapsed)")
        }

        if let queue = engine.queueName {
            parts.append(queue)
        }

        if sleepTimer.remaining != nil {
            parts.append("睡眠 \(sleepTimer.description)")
        }

        return parts.joined(separator: " · ")
    }
}