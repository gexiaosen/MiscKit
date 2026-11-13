import AppKit
import MiscKitCore
import SwiftUI

@MainActor
enum AppIconCache {
    private static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func cached(_ url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async -> NSImage? {
        if let cached = cached(url) { return cached }
        // 与应用图标同理：一屏十几个图标不在主线程逐个取。
        let box = await Task.detached(priority: .userInitiated) {
            ImageBox(image: NSWorkspace.shared.icon(forFile: url.path))
        }.value
        images.setObject(box.image, forKey: url as NSURL)
        return box.image
    }
}

/// 先出占位方块，图标加载完替换；不阻塞首屏。
struct AppIconView: View {
    let url: URL
    @State private var image: NSImage?

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
                        Image(systemName: "app")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
            }
        }
        .frame(width: Layout.Metric.tile, height: Layout.Metric.tile)
        .task(id: url) {
            if let cached = AppIconCache.cached(url) {
                image = cached
                return
            }
            image = await AppIconCache.load(url)
        }
    }
}
