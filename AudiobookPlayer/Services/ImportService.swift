import Foundation
import AVFoundation

enum ImportError: LocalizedError {
    case noAccess(String)
    case copyFailed(String, Error)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noAccess(let name):
            return "读不到「\(name)」，请用系统「文件」App 再试一次。"
        case .copyFailed(let name, let error):
            return "拷贝「\(name)」失败：\(error.localizedDescription)"
        case .unsupported(let name):
            return "「\(name)」不是可播放的音频格式。"
        }
    }
}

/// 一次导入的结果，用于给用户回显「进了几个、跳过几个」
struct ImportOutcome {
    var added: [Audiobook] = []
    var skipped: [String] = []

    var summary: String {
        if added.isEmpty && skipped.isEmpty { return "没有找到可导入的音频文件。" }
        var parts: [String] = []
        if !added.isEmpty { parts.append("已导入 \(added.count) 个文件") }
        if !skipped.isEmpty { parts.append("跳过 \(skipped.count) 个重复文件") }
        return parts.joined(separator: "，") + "。"
    }
}

/// 导入 = 安全作用域授权 → 拷贝进沙盒 → 读时长 → 抠封面 → 写索引。
/// 拷贝落盘而不是保存外部书签，是为了避免 iCloud/外置盘路径失效导致「书打不开」。
enum ImportService {

    /// AVAudioPlayer 原生支持的容器；ogg/opus 不在列，避免「导入成功却播不了」
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "flac"
    ]

    @MainActor
    static func importFiles(urls: [URL], store: LibraryStore) async throws -> ImportOutcome {
        var outcome = ImportOutcome()

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let files = expand(url)
            if files.isEmpty && !url.hasDirectoryPath {
                throw ImportError.unsupported(url.lastPathComponent)
            }

            for file in files {
                if let book = try await importOne(file, store: store) {
                    outcome.added.append(book)
                } else {
                    outcome.skipped.append(file.lastPathComponent)
                }
            }
        }

        store.add(outcome.added)
        return outcome
    }

    /// 单个文件：拷贝 + 时长 + 封面。重复（同名）返回 nil
    @MainActor
    private static func importOne(_ url: URL, store: LibraryStore) async throws -> Audiobook? {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ImportError.unsupported(url.lastPathComponent)
        }

        let title = url.deletingPathExtension().lastPathComponent
        if store.books.contains(where: { $0.title == title }) { return nil }

        let destination = store.audioDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ImportError.copyFailed(url.lastPathComponent, error)
        }

        let duration = await Self.duration(of: destination)
        var cover: String? = nil
        if let name = await CoverService.extractCover(from: destination, into: store.coverDirectory) {
            cover = name
        }

        return Audiobook(
            title: title,
            fileName: destination.lastPathComponent,
            fileExtension: ext,
            duration: duration,
            coverFileName: cover
        )
    }

    /// 文件夹 → 展开成内部所有音频文件；普通文件原样返回
    private static func expand(_ url: URL) -> [URL] {
        guard url.hasDirectoryPath else {
            return supportedExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let item as URL in enumerator {
            if supportedExtensions.contains(item.pathExtension.lowercased()) {
                files.append(item)
            }
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// AVURLAsset 异步读时长，不阻塞主线程
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let cm = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(cm)
            return seconds.isFinite && seconds > 0 ? seconds : 0
        } catch {
            return 0
        }
    }
}