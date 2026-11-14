import SwiftUI

/// 播放页点「列表」弹出的当前播放列表，点哪一集就从哪一集开始播
struct QueueSheet: View {
    @EnvironmentObject private var engine: AudioEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let books = engine.queueBooks

        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                            Button {
                                engine.playFromQueue(book)
                            } label: {
                                row(index: index, book: book, isCurrent: engine.currentBook?.id == book.id)
                            }
                            .buttonStyle(.plain)
                            .id(book.id)

                            Divider()
                                .padding(.leading, 70)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { scrollToCurrent(proxy, books: books, animated: false) }
                .onChange(of: engine.currentBook?.id) { _ in
                    scrollToCurrent(proxy, books: books, animated: true)
                }
            }
            .navigationTitle(engine.queueName ?? "全部音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("\(books.count) 集")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func row(index: Int, book: Audiobook, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: engine.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26)

            BookCoverView(book: book, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(Audiobook.timeString(book.duration))
                    if book.isFinished {
                        Text("已听完")
                    } else if book.progress > 0.005 {
                        Text("已听 \(Int(book.progress * 100))%")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, books: [Audiobook], animated: Bool) {
        guard let id = engine.currentBook?.id,
              books.contains(where: { $0.id == id }) else { return }
        if animated {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}