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

    private var visibleBooks: [Audiobook] {
        store.visibleBooks(keyword: keyword)
    }

    var body: some View {
        List {
            importSection
            librarySection
            summarySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("有声书")
        .searchable(text: $keyword, prompt: "搜索书名")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                sortMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    AboutView()
                } label: {
                    Image(systemName: "info.circle")
                }
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
                    Text("导入整个文件夹")
                    Spacer()
                }
            }
            .disabled(isImporting)
        } footer: {
            Text("支持 mp3 / m4a / m4b / flac / wav 等。文件会拷进 App 内，原文件删掉也不影响；也可以从「文件」App 直接拖进来，或用 iTunes 文件共享拷到 有声书/Documents。")
        }
    }

    private var librarySection: some View {
        Section("书库") {
            if store.books.isEmpty {
                Text("还没有书，先点上面导入。")
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
                Text("共 \(store.books.count) 本 · 总时长 \(Audiobook.timeString(store.totalDuration))")
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

    // MARK: - 动作

    private func delete(_ book: Audiobook) {
        if engine.currentBook?.id == book.id {
            engine.stop()
        }
        store.remove(id: book.id)
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

// MARK: - 行

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

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        List {
            Section("版本") {
                LabeledContent("版本", value: "0.2.0 (Beta)")
                LabeledContent("最低系统", value: "iOS 16.0")
            }
            Section("已实现") {
                Text("· 本地音频导入（文件 / 文件夹 / 拖拽），沙盒拷贝长期有效")
                Text("· 后台播放 + 锁屏 / 耳机线控 / 车机控制")
                Text("· 断点续播，每 5 秒落盘，冷启动自动回到上次那本")
                Text("· 自定义跳过片头 / 片尾，可一键应用到全部")
                Text("· 定时播放（倒计时 3 秒淡出 / 本章结束后停）")
                Text("· 快捷指令与 Siri（播放、暂停、快进、定时）")
                Text("· 自动提取音频内嵌封面")
                Text("· 搜索、排序、来电打断后续播")
            }
            Section("说明") {
                Text("所有音频只保存在本机，不上传、不联网。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
    }
}