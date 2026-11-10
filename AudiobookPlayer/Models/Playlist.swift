import Foundation

/// 歌单：以文件夹为单位导入时自动创建，也可以在书库里手动新建 / 重命名。
/// 只保存书 ID，音频本身仍由 Audiobook 持有，删歌单不会误删文件。
struct Playlist: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var bookIDs: [UUID] = []
    var createdAt: Date = Date()

    var count: Int { bookIDs.count }

    var isEmpty: Bool { bookIDs.isEmpty }
}
