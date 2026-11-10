import Foundation
import AVFoundation
import UIKit

/// 从音频文件里抠出内嵌封面，转成 PNG 存到 Covers/，顺手做个内存缓存。
enum CoverService {
    /// 内存缓存，避免列表滚动时反复读盘
    private static let cache = NSCache<NSString, UIImage>()

    /// 提取封面，返回保存后的文件名；没有封面返回 nil
    static func extractCover(from url: URL, into directory: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }

        for item in metadata {
            guard item.commonKey == .commonKeyArtwork else { continue }
            guard let data = try? await item.load(.dataValue) else { continue }
            guard let image = UIImage(data: data) else { continue }

            // 缩到 1200px 以内，省空间也省内存
            let resized = resize(image, maxSide: 1200)
            guard let png = resized.pngData() else { continue }

            let name = UUID().uuidString + ".png"
            let destination = directory.appendingPathComponent(name)
            do {
                try png.write(to: destination, options: .atomic)
                cache.setObject(resized, forKey: name as NSString)
                return name
            } catch {
                return nil
            }
        }
        return nil
    }

    /// 按文件名取封面图（带缓存）
    static func image(named name: String, directory: URL) -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else {
            return nil
        }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func remove(named name: String) {
        cache.removeObject(forKey: name as NSString)
    }

    private static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}