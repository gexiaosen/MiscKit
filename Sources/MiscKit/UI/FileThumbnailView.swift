import AppKit
import QuickLookThumbnailing
import MiscKitCore
import SwiftUI
import UniformTypeIdentifiers


@MainActor
private enum ThumbnailCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func key(_ url: URL, size: CGSize) -> NSString {
        "\(url.path)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    static func cached(_ url: URL, size: CGSize) -> NSImage? {
        images.object(forKey: key(url, size: size))
    }

    static func load(_ url: URL, size: CGSize) async -> NSImage? {
        let cacheKey = key(url, size: size)
        if let cached = images.object(forKey: cacheKey) { return cached }

        var image: NSImage?
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            image = await quickLook(url: url, size: size)
        }
        if image == nil {
            // 在后台线程异步提取文件图标，避免阻塞主线程响应。
            let box = await Task.detached(priority: .userInitiated) {
                ImageBox(image: NSWorkspace.shared.icon(forFile: url.path))
            }.value
            image = box.image
        }
        if let image { images.setObject(image, forKey: cacheKey) }
        return image
    }

    private static func quickLook(url: URL, size: CGSize) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        let box = await withCheckedContinuation {
            (continuation: CheckedContinuation<ImageBox?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation.map { ImageBox(image: $0.nsImage) })
            }
        }
        return box?.image
    }
}

/// NSImage 不满足 Sendable：跨线程搬运靠它，最终仍在主线程消费。
final class ImageBox: @unchecked Sendable {
    let image: NSImage
    init(image: NSImage) { self.image = image }
}

/// 图片走 Quick Look 缩略图，其余走系统文件图标；先占位后替换，不阻塞结果首屏。
struct FileThumbnailView: View {
    let url: URL
    let isDirectory: Bool
    var size: CGFloat = Layout.Metric.tile
    @State private var image: NSImage?

    private var cgSize: CGSize { CGSize(width: size, height: size) }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: Layout.Metric.tileCornerRadius, style: .continuous)
                    .fill(Theme.tileFill)
                    .overlay {
                        Image(systemName: isDirectory ? "folder" : "doc")
                            .font(.system(size: size * 0.44))
                            .foregroundStyle(Theme.secondaryText)
                    }
            }
        }
        .frame(width: size, height: size)
        .task(id: url.path) {
            if let cached = ThumbnailCache.cached(url, size: cgSize) {
                image = cached
                return
            }
            image = await ThumbnailCache.load(url, size: cgSize)
        }
    }
}
