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

/// 圆角矩形描边路径，从顶边中点开始顺时针绕一圈。
/// 用它配 `.trim(from: 0, to: progress)` 就能得到「沿着封面轮廓走」的进度。
struct RoundedRectRingShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY
        let midX = rect.midX

        var p = Path()
        p.move(to: CGPoint(x: midX, y: minY))

        // 上边右段 → 右上圆角
        p.addLine(to: CGPoint(x: maxX - r, y: minY))
        p.addRelativeArc(
            center: CGPoint(x: maxX - r, y: minY + r),
            radius: r,
            startAngle: .degrees(-90),
            delta: .degrees(90)
        )
        // 右边
        p.addLine(to: CGPoint(x: maxX, y: maxY - r))
        p.addRelativeArc(
            center: CGPoint(x: maxX - r, y: maxY - r),
            radius: r,
            startAngle: .degrees(0),
            delta: .degrees(90)
        )
        // 下边
        p.addLine(to: CGPoint(x: minX + r, y: maxY))
        p.addRelativeArc(
            center: CGPoint(x: minX + r, y: maxY - r),
            radius: r,
            startAngle: .degrees(90),
            delta: .degrees(90)
        )
        // 左边
        p.addLine(to: CGPoint(x: minX, y: minY + r))
        p.addRelativeArc(
            center: CGPoint(x: minX + r, y: minY + r),
            radius: r,
            startAngle: .degrees(180),
            delta: .degrees(90)
        )
        // 回到起点，闭合
        p.addLine(to: CGPoint(x: midX, y: minY))
        return p
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var sleepTimer: SleepTimer

    var onOpen: () -> Void

    var body: some View {
        if let book = engine.currentBook {
            HStack(spacing: 11) {
                coverWithProgress(book: book)

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
            .padding(.vertical, 7)
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

    /// 左侧封面 + 外圈圆角方框进度
    /// 底环和进度环用同一个 path、同一线宽，只是后者被 trim，所以两段首尾必然贴合
    /// 封面放在 TimelineView 外面，只有描边每秒重绘
    private func coverWithProgress(book: Audiobook) -> some View {
        ZStack {
            BookCoverView(book: book, size: 34)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ZStack {
                    RoundedRectRingShape(cornerRadius: 9)
                        .stroke(Color.primary.opacity(0.13), lineWidth: 3)

                    RoundedRectRingShape(cornerRadius: 9)
                        .trim(from: 0, to: fraction)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .round)
                        )
                }
                .padding(1.5)
            }
        }
        .frame(width: 46, height: 46)
        .accessibilityLabel("已听 \(Int(fraction * 100))%")
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