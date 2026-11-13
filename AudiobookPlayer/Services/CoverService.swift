import Foundation
import AVFoundation
import ImageIO
import UIKit

/// 从音频文件里抠出内嵌封面，转成 PNG 存到 Covers/，并按需要降采样取图。
///
/// 关键点：导入时存的是 1200px 的封面。如果列表里直接 `UIImage(contentsOfFile:)`，
/// 每张要解出 1200×1200×4 ≈ 5.7MB 位图，1500 本根本缓存不下，NSCache 会被冲爆，
/// 滚动时就是反复全尺寸解码 + 反复丢缓存 —— 这是滑动卡顿的第二个来源。
/// 所以列表走 `thumbnail(maxPixel:)`，用 CGImageSource 直接解出小图，内存只占几十 KB。
enum CoverService {
    /// 全尺寸封面缓存（播放页大图、锁屏用），限个数量就行
    private static let fullCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// 缩略图缓存，键里带目标像素，列表、迷你条各取所需
    private static let thumbCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

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
                fullCache.setObject(resized, forKey: name as NSString)
                return name
            } catch {
                return nil
            }
        }
        return nil
    }

    /// 按文件名取封面原图（带缓存）。只在播放页大图这种「一次一张」的场景用。
    static func image(named name: String, directory: URL) -> UIImage? {
        if let hit = fullCache.object(forKey: name as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else {
            return nil
        }
        fullCache.setObject(image, forKey: name as NSString, cost: cost(of: image))
        return image
    }

    /// 按文件名取降采样后的封面。
    /// - Parameter maxPixel: 目标最长边像素，列表里传「尺寸 × 3」即可
    ///
    /// 走 `CGImageSourceCreateThumbnailAtIndex`，只解出小图，不会先把 1200px 整张读进内存。
    static func thumbnail(named name: String, directory: URL, maxPixel: CGFloat) -> UIImage? {
        let pixels = max(32, Int((maxPixel).rounded()))
        let key = "\(name)@\(pixels)" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }

        let url = directory.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // 降采样失败就退回原图，至少别显示空
            return image(named: name, directory: directory)
        }

        let image = UIImage(cgImage: cgImage)
        thumbCache.setObject(
            image,
            forKey: key,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return image
    }

    static func remove(named name: String) {
        fullCache.removeObject(forKey: name as NSString)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
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
