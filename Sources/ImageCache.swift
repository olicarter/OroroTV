import ImageIO
import SwiftUI
import UIKit

/// Posters and hero backdrops kept in memory, so an image that has already loaded, or was
/// prefetched before it was needed, shows straight away instead of fading in.
///
/// Two tiers: decoded images, scaled to the size they're drawn at, for what's on screen; and the
/// compressed bytes of hero backdrops prefetched for tiles in view, which are 250–550 KB each and
/// up to 4K, far too big to keep decoded for every tile.
@MainActor
final class ImageCache {
    enum Kind {
        case poster, backdrop

        /// Longest side to decode at: posters are at most a few hundred points wide; backdrops
        /// fill the screen under a dark gradient.
        var maxPixelSize: CGFloat { self == .poster ? 720 : 1920 }
    }

    static let shared = ImageCache()

    private let images = NSCache<NSURL, UIImage>()
    private let data = NSCache<NSURL, NSData>()
    private var imageLoads: [URL: Task<UIImage?, Never>] = [:]
    private var dataLoads: [URL: Task<Data?, Never>] = [:]

    /// Prefetches are a guess, so they don't spend cellular data or ignore Low Data Mode.
    private let prefetchSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: config)
    }()

    private init() {
        images.totalCostLimit = 200 << 20
        data.totalCostLimit = 60 << 20
    }

    func cached(_ url: URL) -> UIImage? { images.object(forKey: url as NSURL) }

    /// Downloads (or takes prefetched bytes) and decodes off the main thread; concurrent requests
    /// for one URL share a load.
    func image(for url: URL, kind: Kind = .poster) async -> UIImage? {
        if let image = cached(url) { return image }
        let load = imageLoads[url] ?? Task {
            // A second try covers joining a prefetch that the network rules refused.
            var bytes = await self.bytes(for: url, session: .shared)
            if bytes == nil { bytes = await self.bytes(for: url, session: .shared) }
            guard let bytes else { return nil }
            let maxPixelSize = kind.maxPixelSize
            return await Task.detached(priority: .userInitiated) {
                Self.decode(bytes, maxPixelSize: maxPixelSize)
            }.value
        }
        imageLoads[url] = load
        let image = await load.value
        imageLoads[url] = nil
        if let image, let cg = image.cgImage {
            images.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    func prefetch(_ urls: some Sequence<URL?>) {
        for case let url? in urls where cached(url) == nil && imageLoads[url] == nil {
            Task { _ = await image(for: url) }
        }
    }

    /// Fetches the compressed bytes only; `image(for:kind:)` decodes them when the image is shown.
    func prefetchData(_ urls: some Sequence<URL?>) {
        for case let url? in urls where cached(url) == nil && data.object(forKey: url as NSURL) == nil && dataLoads[url] == nil {
            Task { _ = await bytes(for: url, session: prefetchSession) }
        }
    }

    private func bytes(for url: URL, session: URLSession) async -> Data? {
        if let bytes = data.object(forKey: url as NSURL) { return bytes as Data }
        let load = dataLoads[url] ?? Task.detached(priority: .utility) {
            guard let (bytes, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { return nil }
            return bytes
        }
        dataLoads[url] = load
        let bytes = await load.value
        dataLoads[url] = nil
        if let bytes { data.setObject(bytes as NSData, forKey: url as NSURL, cost: bytes.count) }
        return bytes
    }

    /// Decodes now, at no more than `maxPixelSize` on the longest side.
    nonisolated private static func decode(_ bytes: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }
}

extension View {
    /// When this item appears, starts loading the posters of the next few in its list, so they're
    /// ready by the time they scroll into view.
    func prefetchPosters(after index: Int, in urls: [URL?], count: Int = 8) -> some View {
        onAppear { ImageCache.shared.prefetch(urls.dropFirst(index + 1).prefix(count)) }
    }
}
