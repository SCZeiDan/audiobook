import SwiftUI

/// 主页 —— 对齐 Apple 播客的「首页」：继续收听 + 最近添加 + 歌单
struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var engine: AudioEngine

    var onOpenPlayer: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let book = featuredBook {
                    featuredCard(book)
                }

                if store.books.isEmpty {
                    emptyCard
                } else {
                    recentlyAddedSection
                }

                if !store.playlists.isEmpty {
                    playlistSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("主页")
    }

    // MARK: - 数据

    /// 优先当前播放的，其次最近听过且没听完的
    private var featuredBook: Audiobook? {
        if let current = engine.currentBook { return current }
        return store.books
            .filter { $0.lastPlayedAt != nil && !$0.isFinished }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }

    private var recentlyAdded: [Audiobook] {
        Array(store.books.sorted { $0.addedAt > $1.addedAt }.prefix(12))
    }

    // MARK: - 继续收听

    private func featuredCard(_ book: Audiobook) -> some View {
        let isCurrent = engine.currentBook?.id == book.id
        let progress = isCurrent ? currentProgress : book.progress
        let caption = isCurrent ? "正在播放" : (book.lastPosition > 1 ? "继续收听" : "开始收听")

        return Button {
            if isCurrent {
                onOpenPlayer()
            } else {
                engine.play(book)
                onOpenPlayer()
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        BookCoverView(book: book, size: 88)
                        Image(systemName: isCurrent ? "waveform" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 6, y: 6)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(caption)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Text(book.title)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Text(detailLine(book, progress: progress))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                // 正在播放时进度条每秒自己走，其余情况静态
                if isCurrent {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ProgressView(value: min(max(currentProgress, 0), 1))
                            .tint(Color.accentColor)
                    }
                    .padding(.top, 12)
                } else {
                    ProgressView(value: min(max(book.progress, 0), 1))
                        .tint(Color.accentColor)
                        .padding(.top, 12)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    /// 正在播放时用播放器里的实时位置，其余看索引
    private var currentProgress: Double {
        guard engine.duration > 0 else { return 0 }
        return engine.currentTime / engine.duration
    }

    private func detailLine(_ book: Audiobook, progress: Double) -> String {
        let total = Audiobook.timeString(book.duration)
        let remaining = Audiobook.timeString(max(0, book.duration * (1 - progress)))
        if progress > 0.005 {
            return "已听 \(Int(progress * 100))% · 还剩 \(remaining) / 共 \(total)"
        }
        return "共 \(total)"
    }

    // MARK: - 最近添加

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("最近添加", detail: "\(store.books.count) 本")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(recentlyAdded) { book in
                        Button {
                            engine.play(book)
                            onOpenPlayer()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                BookCoverView(book: book, size: 128)
                                    .overlay(alignment: .bottomLeading) {
                                        if book.progress > 0.005 {
                                            ProgressView(value: book.progress)
                                                .tint(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.bottom, 6)
                                        }
                                    }

                                Text(book.title)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)

                                Text(Audiobook.timeString(book.duration))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 128, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    // MARK: - 歌单

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("歌单", detail: "\(store.playlists.count) 个")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(store.playlists) { list in
                        let stats = store.playlistStats(list)
                        Button {
                            engine.playPlaylist(list)
                            onOpenPlayer()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    LinearGradient(
                                        colors: [
                                            Color.accentColor.opacity(0.28),
                                            Color.accentColor.opacity(0.10)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )

                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 34, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .frame(width: 128, height: 128)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                Text(list.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)

                                Text("\(stats.count) 集 · \(Audiobook.timeString(stats.duration))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 128, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    // MARK: - 空态

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("还没有音频")
                .font(.headline)

            Text("去「资料库」点导入；或者把音频文件、整个文件夹直接拖进「文件」App 里的 雅拉马喜/Audio，切回来就会自动收进书库，文件夹还会自动变成歌单。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - 小组件

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer(minLength: 0)
            if let detail = detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}