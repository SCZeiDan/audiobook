import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var engine: AudioEngine

    var onOpenPlayer: () -> Void

    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var isImporting = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var keyword = ""
    @State private var isDropTargeted = false

    /// 正在重命名的歌单
    @State private var renameTarget: Playlist?
    /// 正在确认删除的歌单
    @State private var deleteTarget: Playlist?

    private var visibleBooks: [Audiobook] {
        store.visibleBooks(keyword: keyword)
    }

    var body: some View {
        List {
            importSection
            if !store.playlists.isEmpty { playlistSection }
            librarySection
            summarySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("雅拉马喜")
        .searchable(text: $keyword, prompt: "搜索书名")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                sortMenu
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): performImport(urls)
            case .failure(let error): show(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): performImport(urls)
            case .failure(let error): show(error.localizedDescription)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            performImport(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .alert("提示", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onChange(of: engine.lastError) { value in
            guard let value = value, !value.isEmpty else { return }
            alertMessage = value
            showAlert = true
            engine.lastError = nil
        }
        .sheet(item: $renameTarget) { list in
            PlaylistNameSheet(title: "重命名歌单", initial: list.name) { name in
                store.renamePlaylist(list.id, to: name)
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("只删歌单，保留音频") { deletePlaylist(deleteFiles: false) }
            Button("歌单和音频一起删", role: .destructive) { deletePlaylist(deleteFiles: true) }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("「一起删」会把歌单里的音频文件从手机里彻底移除，不可恢复。")
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 34))
                            Text("松手导入音频")
                                .font(.headline)
                        }
                        .foregroundStyle(Color.accentColor)
                    )
                    .padding(24)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 分区

    private var importSection: some View {
        Section {
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入音频文件")
                    Spacer()
                    if isImporting { ProgressView() }
                }
            }
            .disabled(isImporting)

            Button {
                showFolderImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                    Text("导入文件夹（自动成歌单）")
                    Spacer()
                }
            }
            .disabled(isImporting)
        } footer: {
            Text("支持 mp3 / m4a / m4b / flac / wav 等。选文件夹导入时，文件夹名会变成歌单名，里面的音频按文件名顺序排队；文件会拷进 App 内，原文件删掉也不影响。")
        }
    }

    private var playlistSection: some View {
        Section {
            ForEach(store.playlists) { list in
                PlaylistRow(
                    playlist: list,
                    books: store.books(in: list),
                    isCurrent: engine.queueName == list.name && engine.currentBook != nil
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    engine.playPlaylist(list)
                    onOpenPlayer()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = list
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        engine.playPlaylist(list)
                        onOpenPlayer()
                    } label: {
                        Label("播放整个歌单", systemImage: "play.fill")
                    }
                    Button {
                        renameTarget = list
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteTarget = list
                    } label: {
                        Label("删除歌单", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("歌单")
        } footer: {
            Text("点歌单从第一集没听完的开始连播；左滑删除，可以只解散歌单，也可以连音频一起删。")
        }
    }

    private var librarySection: some View {
        Section("全部音频") {
            if store.books.isEmpty {
                Text("还没有音频，先点上面导入。")
                    .foregroundStyle(.secondary)
            } else if visibleBooks.isEmpty {
                Text("没有匹配「\(keyword)」的书。")
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleBooks) { book in
                BookRow(book: book, isCurrent: engine.currentBook?.id == book.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.play(book)
                        onOpenPlayer()
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            delete(book)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private var summarySection: some View {
        Section {
            if store.books.isEmpty {
                EmptyView()
            } else {
                Text("共 \(store.books.count) 本 · \(store.playlists.count) 个歌单 · 总时长 \(Audiobook.timeString(store.totalDuration))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $store.sortOrder) {
                ForEach(LibraryStore.SortOrder.allCases) { order in
                    Label(order.label, systemImage: order.icon).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }

    private var deleteTitle: String {
        guard let list = deleteTarget else { return "删除歌单" }
        return "删除歌单「\(list.name)」？"
    }

    // MARK: - 动作

    private func delete(_ book: Audiobook) {
        if engine.currentBook?.id == book.id {
            engine.stop()
        }
        store.remove(id: book.id)
    }

    private func deletePlaylist(deleteFiles: Bool) {
        guard let list = deleteTarget else { return }
        if let current = engine.currentBook,
           store.books(in: list).contains(where: { $0.id == current.id }) {
            engine.stop()
        }
        store.removePlaylist(id: list.id, deleteFiles: deleteFiles)
        deleteTarget = nil
    }

    private func show(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func performImport(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            do {
                let outcome = try await ImportService.importFiles(urls: urls, store: store)
                isImporting = false
                if engine.currentBook == nil, let first = outcome.added.first {
                    engine.startFresh(first)
                }
                show(outcome.summary)
            } catch {
                isImporting = false
                show(error.localizedDescription)
            }
        }
    }
}

// MARK: - 歌单行

struct PlaylistRow: View {
    let playlist: Playlist
    let books: [Audiobook]
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note.list")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .lineLimit(1)
                Text("\(books.count) 集 · \(Audiobook.timeString(totalDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }

    private var totalDuration: Double {
        books.reduce(0) { $0 + $1.duration }
    }
}

// MARK: - 单本行

struct BookRow: View {
    let book: Audiobook
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(book: book, size: 48)
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 4, y: 4)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(Audiobook.timeString(book.duration))
                    if book.skipIntro > 0 || book.skipOutro > 0 {
                        Text("片头 \(Int(book.skipIntro))s / 片尾 \(Int(book.skipOutro))s")
                    }
                    if book.isFinished {
                        Text("已听完")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if book.progress > 0.005 {
                    ProgressView(value: book.progress)
                        .tint(isCurrent ? Color.accentColor : Color.secondary)
                }
            }

            Spacer(minLength: 0)

            Text("\(Int(book.progress * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 封面

struct BookCoverView: View {
    let book: Audiobook?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    private var loadedImage: UIImage? {
        guard let name = book?.coverFileName else { return nil }
        return CoverService.image(named: name, directory: LibraryStore.shared.coverDirectory)
    }
}
