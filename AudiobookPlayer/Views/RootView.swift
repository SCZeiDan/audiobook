import SwiftUI

struct RootView: View {
    @EnvironmentObject private var engine: AudioEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            LibraryView(onOpenPlayer: { showPlayer = true })
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if engine.currentBook != nil {
                        MiniPlayerBar(onOpen: { showPlayer = true })
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                            .background(.bar)
                    }
                }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task {
            await bootstrap()
        }
        .onChange(of: scenePhase) { phase in
            // 切后台/锁屏前落盘，避免掉电丢进度
            if phase != .active {
                AudioEngine.shared.persistProgress()
            }
        }
    }

    private func bootstrap() async {
        AudioEngine.shared.restoreLastSession()
        await LibraryStore.shared.refreshMissingDurations()
        AudioEngine.shared.refreshCurrentBookFromStore()
    }
}

// MARK: - 迷你播放条

struct MiniPlayerBar: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var sleepTimer: SleepTimer

    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    BookCoverView(book: engine.currentBook, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.currentBook?.title ?? "")
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                engine.toggle()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            Button {
                engine.playNext()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 40)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 56)
    }

    private var subtitle: String {
        if sleepTimer.isActive {
            return sleepTimer.description
        }
        let time = "\(Audiobook.timeString(engine.currentTime)) / \(Audiobook.timeString(engine.duration))"
        if engine.isPlaying {
            return time
        }
        return engine.currentTime > 1 ? "已暂停 · \(time)" : time
    }
}