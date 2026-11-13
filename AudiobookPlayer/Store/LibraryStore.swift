import Foundation
import Combine

/// 书库与歌单的唯一数据源：负责落盘、增删、排序、进度更新、磁盘自修复。
///
/// 1500 本以上的书库有个坑：SwiftUI 的 body 里任何一次全量排序 / 建字典 /
/// 目录 stat 都会变成可感知的卡顿。所以这里做了四件事：
/// 1. `books` 不再是 `@Published`，播放中的进度回写走 `recordProgress(_:notifyUI:)`
///    静默路径，不惊动界面；只有真正的结构变化才 `objectWillChange.send()`；
/// 2. 排序结果和 id 索引带缓存，数据一变就失效；
/// 3. JSON 编码去掉 prettyPrinted，写盘挪到后台串行队列，主线程不碰磁盘；
/// 4. 歌单行改用 `playlistStats(_:)`，不再为每一行重建 1500 项字典。
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    /// 书库排序方式
    enum SortOrder: String, CaseIterable, Identifiable {
        case added
        case title
        case recent
        case progress

        var id: String { rawValue }

        var label: String {
            switch self {
            case .added: return "导入顺序"
            case .title: return "书名"
            case .recent: return "最近播放"
            case .progress: return "未听完优先"
            }
        }

        var icon: String {
            switch self {
            case .added: return "arrow.down.doc"
            case .title: return "textformat.abc"
            case .recent: return "clock"
            case .progress: return "chart.bar"
            }
        }
    }

    /// 书库。故意不加 `@Published`：播放时每 30 秒一次的进度回写如果触发全量刷新，
    /// 1500 行列表就要反复重排。结构变化由 `libraryChanged()` 手动发通知。
    private(set) var books: [Audiobook] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published var sortOrder: SortOrder = .added {
        didSet { sortedCache = nil }
    }

    // MARK: - 缓存

    private var sortedCache: [Audiobook]?
    private var indexCache: [UUID: Audiobook]?
    private var storageCache: (bytes: Int64, at: Date)?
    private var lastReconcileAt: Date = .distantPast

    private let fm = FileManager.default
    private static let writeQueue = DispatchQueue(
        label: "com.yg.audiobook.library-write",
        qos: .utility
    )

    /// 音频文件统一放 Documents/Audio/，避免外部 URL 失效
    var audioDirectory: URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Audio", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 封面缓存放 Application Support/Covers/，不进 Documents 以免被用户误删
    var coverDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Covers", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    private var indexURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent("library.json")
    }

    /// 索引文件结构。0.2 及以前存的是裸数组，这里做兼容读取
    private struct LibraryFile: Codable {
        var version: Int = 2
        var books: [Audiobook] = []
        var playlists: [Playlist] = []
    }

    private init() {
        load()
        reconcile()
    }

    // MARK: - 缓存失效

    /// 结构变化：清缓存 + 通知界面重绘
    private func libraryChanged() {
        sortedCache = nil
        indexCache = nil
        storageCache = nil
        objectWillChange.send()
    }

    /// 只清缓存，不发通知（静默回写进度时用）
    private func invalidateCaches() {
        sortedCache = nil
        indexCache = nil
        storageCache = nil
    }

    // MARK: - 文件定位

    func fileURL(for book: Audiobook) -> URL {
        audioDirectory.appendingPathComponent(book.fileName)
    }

    func coverURL(for fileName: String) -> URL {
        coverDirectory.appendingPathComponent(fileName)
    }

    // MARK: - 持久化

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(LibraryFile.self, from: data) {
            books = file.books
            playlists = file.playlists
        } else if let legacy = try? decoder.decode([Audiobook].self, from: data) {
            // 0.2 及以前：只有书，没有歌单
            books = legacy
            playlists = []
        }
        invalidateCaches()
    }

    /// 编码在主线程（1500 条约 10ms），写盘丢到后台串行队列，绝不阻塞滚动
    func save() {
        let file = LibraryFile(version: 2, books: books, playlists: playlists)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        let url = indexURL
        LibraryStore.writeQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 书籍增删改

    func add(_ newBooks: [Audiobook]) {
        guard !newBooks.isEmpty else { return }
        books.append(contentsOf: newBooks)
        libraryChanged()
        save()
    }

    func update(_ book: Audiobook) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i] = book
        libraryChanged()
        save()
    }

    /// 播放进度回写（高频路径）。
    ///
    /// - Parameter notifyUI: `true` 表示暂停 / 切集 / 退到后台这类用户能感知的时刻，
    ///   需要刷新列表上的进度条；播放中的定时回写传 `false`，只更新内存和磁盘。
    func recordProgress(_ book: Audiobook, notifyUI: Bool) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].lastPosition = book.lastPosition
        books[i].lastPlayedAt = book.lastPlayedAt
        if book.duration > 0 {
            books[i].duration = book.duration
        }
        invalidateCaches()
        if notifyUI {
            objectWillChange.send()
        }
        save()
    }

    private func deleteFile(of book: Audiobook) {
        try? fm.removeItem(at: fileURL(for: book))
        if let cover = book.coverFileName {
            try? fm.removeItem(at: coverURL(for: cover))
        }
    }

    func remove(at offsets: IndexSet) {
        let doomed = offsets.compactMap { books.indices.contains($0) ? books[$0] : nil }
        guard !doomed.isEmpty else { return }
        doomed.forEach(deleteFile(of:))
        let ids = Set(doomed.map { $0.id })
        books.removeAll { ids.contains($0.id) }
        purgePlaylists(ids)
        libraryChanged()
        save()
    }

    func remove(id: UUID) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        remove(at: IndexSet(integer: index))
    }

    func rename(_ book: Audiobook, to title: String) {
        var copy = book
        copy.title = title
        update(copy)
    }

    /// 批量设置片头片尾；ids 为空表示整个书库
    func applySkipSettings(intro: Double, outro: Double, to ids: Set<UUID>? = nil) {
        for i in books.indices {
            if let ids = ids, !ids.contains(books[i].id) { continue }
            books[i].skipIntro = intro
            books[i].skipOutro = outro
        }
        libraryChanged()
        save()
    }

    // MARK: - 查询（全部走缓存）

    /// O(1) 取单本
    func book(id: UUID) -> Audiobook? {
        if indexCache == nil {
            indexCache = Dictionary(
                books.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return indexCache?[id]
    }

    func books(in playlist: Playlist) -> [Audiobook] {
        playlist.bookIDs.compactMap { book(id: $0) }
    }

    /// 歌单行要显示的「几集 · 多长」，避免每行都遍历全库
    func playlistStats(_ playlist: Playlist) -> (count: Int, duration: Double) {
        var count = 0
        var total: Double = 0
        for id in playlist.bookIDs {
            guard let b = book(id: id) else { continue }
            count += 1
            total += b.duration
        }
        return (count, total)
    }

    // MARK: - 歌单

    func playlist(id: UUID?) -> Playlist? {
        guard let id = id else { return nil }
        return playlists.first { $0.id == id }
    }

    /// 同名歌单则把书并进去，避免反复导入文件夹生成一堆同名歌单
    @discardableResult
    func createPlaylist(name: String, bookIDs: [UUID]) -> Playlist? {
        guard !bookIDs.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名歌单" : trimmed

        if let i = playlists.firstIndex(where: { $0.name == finalName }) {
            for id in bookIDs where !playlists[i].bookIDs.contains(id) {
                playlists[i].bookIDs.append(id)
            }
            save()
            return playlists[i]
        }

        let list = Playlist(name: finalName, bookIDs: bookIDs)
        playlists.append(list)
        save()
        return list
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = trimmed
        save()
    }

    /// 删除歌单。deleteFiles = true 时连歌单里的音频一起删，否则只解散歌单
    func removePlaylist(id: UUID, deleteFiles: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let ids = Set(playlists[index].bookIDs)

        if deleteFiles && !ids.isEmpty {
            books.filter { ids.contains($0.id) }.forEach(deleteFile(of:))
            books.removeAll { ids.contains($0.id) }
            for i in playlists.indices {
                playlists[i].bookIDs.removeAll { ids.contains($0) }
            }
        }

        playlists.removeAll { $0.id == id }
        libraryChanged()
        save()
    }

    /// 从歌单里移除单本书（不动文件）
    func removeBook(_ bookID: UUID, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].bookIDs.removeAll { $0 == bookID }
        save()
    }

    /// 书被删掉后，把残留的 ID 从所有歌单里清掉
    private func purgePlaylists(_ ids: Set<UUID>) {
        for i in playlists.indices {
            playlists[i].bookIDs.removeAll { ids.contains($0) }
        }
    }

    // MARK: - 列表

    /// 搜索 + 排序后的结果，供书库列表使用。排序结果带缓存，body 反复求值也不重排。
    func visibleBooks(keyword: String) -> [Audiobook] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return sortedAll() }
        return sortedAll().filter { $0.title.localizedCaseInsensitiveContains(key) }
    }

    private func sortedAll() -> [Audiobook] {
        if let cached = sortedCache { return cached }
        var list = books
        switch sortOrder {
        case .added:
            list.sort { $0.addedAt < $1.addedAt }
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recent:
            list.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .progress:
            list.sort { $0.progress < $1.progress }
        }
        sortedCache = list
        return list
    }

    var totalDuration: Double {
        books.reduce(0) { $0 + $1.duration }
    }

    /// 已占用空间（音频 + 封面），用于设置页显示。1500 个文件 stat 一遍要十几毫秒，
    /// 所以结果缓存 60 秒。
    var storageBytes: Int64 {
        if let cached = storageCache, Date().timeIntervalSince(cached.at) < 60 {
            return cached.bytes
        }
        var total: Int64 = 0
        for dir in [audioDirectory, coverDirectory] {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names {
                let path = dir.appendingPathComponent(name).path
                let attrs = try? fm.attributesOfItem(atPath: path)
                total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        storageCache = (total, Date())
        return total
    }

    /// 清空整个书库：删索引、删音频、删封面
    func clearAll() {
        for book in books {
            deleteFile(of: book)
        }
        books = []
        playlists = []
        try? fm.removeItem(at: indexURL)
        libraryChanged()
        save()
    }

    // MARK: - 自修复

    /// 启动 / 回到前台时对齐磁盘与索引：
    /// 1. 丢掉已消失的文件
    /// 2. 收养直接丢进 Audio/ 的散文件
    /// 3. 收养丢进 Audio/ 的子文件夹 —— 文件夹名当歌单名，里面的音频搬进根目录
    func reconcile() {
        // 回到前台会触发一次，启动时 .task 也会触发一次，1.5 秒内只认真扫一遍
        let now = Date()
        guard now.timeIntervalSince(lastReconcileAt) > 1.5 else { return }
        lastReconcileAt = now

        var kept: [Audiobook] = []
        for book in books where fm.fileExists(atPath: fileURL(for: book).path) {
            kept.append(book)
        }

        var known = Set(kept.map { $0.fileName })
        var adopted = false
        var folderDrops: [String: [UUID]] = [:]

        let names = (try? fm.contentsOfDirectory(atPath: audioDirectory.path)) ?? []
        for name in names {
            let full = audioDirectory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // 文件夹 = 歌单。里面的音频逐个搬进根目录改名 UUID，避免同名覆盖
                let folderName = name
                let inner = ((try? fm.contentsOfDirectory(atPath: full.path)) ?? [])
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                var ids: [UUID] = []

                for entry in inner {
                    let ext = (entry as NSString).pathExtension.lowercased()
                    guard ImportService.supportedExtensions.contains(ext) else { continue }

                    let destination = audioDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    guard (try? fm.moveItem(at: full.appendingPathComponent(entry), to: destination)) != nil else {
                        continue
                    }

                    let book = Audiobook(
                        title: (entry as NSString).deletingPathExtension,
                        fileName: destination.lastPathComponent,
                        fileExtension: ext
                    )
                    kept.append(book)
                    known.insert(book.fileName)
                    ids.append(book.id)
                    adopted = true
                }

                if !ids.isEmpty { folderDrops[folderName] = ids }

                // 音频都搬走了就删掉空文件夹，下次启动不再重复扫
                if ((try? fm.contentsOfDirectory(atPath: full.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: full)
                }
            } else {
                guard !known.contains(name) else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                guard ImportService.supportedExtensions.contains(ext) else { continue }
                let book = Audiobook(
                    title: (name as NSString).deletingPathExtension,
                    fileName: name,
                    fileExtension: ext
                )
                kept.append(book)
                known.insert(name)
                adopted = true
            }
        }

        if kept.count != books.count || adopted {
            let alive = Set(kept.map { $0.id })
            let removed = Set(books.map { $0.id }).subtracting(alive)
            books = kept
            purgePlaylists(removed)
            invalidateCaches()
            save()
        }

        // 文件夹 → 歌单。createPlaylist 遇到同名会合并，反复拖同一个文件夹不会堆歌单
        for (folderName, ids) in folderDrops {
            createPlaylist(name: folderName, bookIDs: ids)
        }
    }

    /// 给「收养」进来的文件补时长；读不到就等首次播放时由播放器补齐
    func refreshMissingDurations() async {
        var changed = false
        for book in books where book.duration <= 0 {
            let value = await ImportService.duration(of: fileURL(for: book))
            guard value > 0, let index = books.firstIndex(where: { $0.id == book.id }) else { continue }
            books[index].duration = value
            changed = true
        }
        if changed {
            libraryChanged()
            save()
        }
    }
}
