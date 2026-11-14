import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var sleepTimer: SleepTimer
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showSleepSheet = false
    @State private var showTuningSheet = false
    @State private var showQueueSheet = false

    private let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 0)

                cover

                VStack(spacing: 6) {
                    Text(engine.currentBook?.title ?? "未在播放")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 8)

                    if let name = engine.queueName {
                        Text("来自「\(name)」")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }

                    if let book = engine.currentBook, book.skipIntro > 0 || book.skipOutro > 0 {
                        Text("跳过片头 \(Int(book.skipIntro))s · 片尾 \(Int(book.skipOutro))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                progressSection
                controls
                extraRow

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if let book = engine.currentBook { engine.startFresh(book) }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showSleepSheet) {
                SleepTimerSheet()
                    .environmentObject(sleepTimer)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showTuningSheet) {
                BookTuningSheet()
                    .environmentObject(engine)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showQueueSheet) {
                QueueSheet()
                    .environmentObject(engine)
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: - 子视图

    private var cover: some View {
        ZStack {
            if let image = coverImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "headphones")
                    .font(.system(size: 84, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
    }

    private var coverImage: UIImage? {
        guard let name = engine.currentBook?.coverFileName else { return nil }
        // 240pt 的封面，按 3x 取 720px 就够，不必读 1200px 原图
        return CoverService.thumbnail(
            named: name,
            directory: LibraryStore.shared.coverDirectory,
            maxPixel: 720
        )
    }

    private var progressSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : clock.currentTime },
                    set: { newValue in
                        isScrubbing = true
                        scrubValue = newValue
                    }
                ),
                in: 0...max(clock.duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = clock.currentTime
                    } else {
                        engine.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
            )

            HStack {
                Text(Audiobook.timeString(isScrubbing ? scrubValue : clock.currentTime))
                Spacer()
                Text("-" + Audiobook.timeString(max(0, clock.duration - (isScrubbing ? scrubValue : clock.currentTime))))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            Button { engine.playPrevious() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }

            Button { engine.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 26))
                    .frame(width: 44, height: 44)
            }

            Button { engine.toggle() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }

            Button { engine.skip(by: 15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 26))
                    .frame(width: 44, height: 44)
            }

            Button { engine.playNext() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var extraRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showQueueSheet = true
                } label: {
                    chip(icon: "list.bullet", text: queueChipText)
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(rates, id: \.self) { value in
                        Button {
                            engine.setRate(Float(value))
                        } label: {
                            HStack {
                                Text(String(format: "%.2fx", value))
                                if abs(Double(engine.rate) - value) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    chip(icon: "speedometer", text: String(format: "%.2fx", engine.rate))
                }

                Button {
                    showSleepSheet = true
                } label: {
                    chip(
                        icon: "moon.zzz",
                        text: sleepTimer.isActive ? sleepTimer.description : "定时播放"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showTuningSheet = true
                } label: {
                    chip(icon: "scissors", text: "片头片尾")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
        }
        .font(.footnote)
    }

    private var queueChipText: String {
        engine.queue.isEmpty ? "播放列表" : "播放列表 \(engine.queue.count)"
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }
}
