import Foundation
import Combine

/// 书库：持有全部 Audiobook，负责落盘、增删、排序、进度更新。
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

    @Published private(set) var books: [Audiobook] = []
    @Published var sortOrder: SortOrder = .added

    private let fm = FileManager.default

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

    private init() {
        load()
        reconcile()
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
        books = (try? decoder.decode([Audiobook].self, from: data)) ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(books) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - 增删改

    func add(_ newBooks: [Audiobook]) {
        guard !newBooks.isEmpty else { return }
        books.append(contentsOf: newBooks)
        save()
    }

    func update(_ book: Audiobook) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i] = book
        save()
    }

    func remove(at offsets: IndexSet) {
        let doomed = offsets.compactMap { books.indices.contains($0) ? books[$0] : nil }
        for book in doomed {
            try? fm.removeItem(at: fileURL(for: book))
            if let cover = book.coverFileName {
                try? fm.removeItem(at: coverURL(for: cover))
            }
        }
        for index in offsets.sorted(by: >) where books.indices.contains(index) {
            books.remove(at: index)
        }
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

    /// 批量设置片头片尾，适合整季分集统一处理
    func applySkipSettings(intro: Double, outro: Double) {
        for i in books.indices {
            books[i].skipIntro = intro
            books[i].skipOutro = outro
        }
        save()
    }

    // MARK: - 列表

    /// 搜索 + 排序后的结果，供书库列表使用
    func visibleBooks(keyword: String) -> [Audiobook] {
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

        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(key) }
    }

    var totalDuration: Double {
        books.reduce(0) { $0 + $1.duration }
    }

    // MARK: - 自修复

    /// 启动时对齐磁盘与索引：丢掉已消失的文件，收养手工丢进 Audio/ 的文件
    func reconcile() {
        var kept: [Audiobook] = []
        for book in books where fm.fileExists(atPath: fileURL(for: book).path) {
            kept.append(book)
        }

        let names = (try? fm.contentsOfDirectory(atPath: audioDirectory.path)) ?? []
        let known = Set(kept.map { $0.fileName })
        for name in names where !known.contains(name) {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ImportService.supportedExtensions.contains(ext) else { continue }
            let title = (name as NSString).deletingPathExtension
            kept.append(
                Audiobook(
                    title: title,
                    fileName: name,
                    fileExtension: ext
                )
            )
        }

        if kept.count != books.count {
            books = kept
            save()
        }
    }

    /// 给「收养」进来的文件补时长；读不到就等首次播放时由播放器补齐
    func refreshMissingDurations() async {
        for book in books where book.duration <= 0 {
            let value = await ImportService.duration(of: fileURL(for: book))
            guard value > 0, let index = books.firstIndex(where: { $0.id == book.id }) else { continue }
            books[index].duration = value
        }
        save()
    }
}