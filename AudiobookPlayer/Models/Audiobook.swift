import Foundation

/// 一本书 = 一个本地音频文件（一个 mp3 / m4a / m4b 分集）。
/// 所有字段都可编码，整库以 JSON 形式落盘，冷启动直接恢复。
struct Audiobook: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 展示标题，默认取文件名
    var title: String
    /// 沙盒 Documents/Audio/ 下的文件名
    var fileName: String
    /// 扩展名，仅用于展示
    var fileExtension: String = "mp3"
    /// 总时长（秒），导入时由 AVURLAsset 读取；读不到时等首次播放补齐
    var duration: Double = 0
    /// 跳过片头（秒）
    var skipIntro: Double = 0
    /// 跳过片尾（秒）
    var skipOutro: Double = 0
    /// 断点续播位置（秒）
    var lastPosition: Double = 0
    var lastPlayedAt: Date? = nil
    var addedAt: Date = Date()
    /// 提取出来的封面文件名（Application Support/Covers/ 下），没有则为 nil
    var coverFileName: String? = nil

    /// 0...1，用于书库列表的进度条
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(lastPosition / duration, 0), 1)
    }

    /// 已经播完（留 1% 容差，避免片尾跳过导致永远差几秒）
    var isFinished: Bool {
        duration > 0 && lastPosition >= duration - max(skipOutro, 1)
    }

    /// mm:ss / h:mm:ss
    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}