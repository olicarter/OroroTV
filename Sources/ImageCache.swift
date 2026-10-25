import ImageIO
import SwiftUI
import UIKit

/// Posters and hero backdrops kept in memory, so an image that has already loaded, or was
/// prefetched before it was needed, shows on the first frame instead of fading in.
///
/// Posters are small and kept decoded. Hero backdrops are 250–550 KB and up to 4K, and decoding
/// one takes long enough (~50 ms) to stall opening a page, so tiles decode their hero in the
/// background as they come into view. Only the most recent few stay decoded (enough for every tile
/// on screen); their compressed bytes are kept longer.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    /// Longest side to decode at: posters are at most a few hundred points wide; backdrops fill
    /// the screen under a dark gradient.
    nonisolated private static let posterPixels: CGFloat = 720
    nonisolated private static let heroPixels: CGFloat = 1920
    /// About 8 MB each decoded; more than the tiles on screen at once.
    private static let heroLimit = 16

    private let posters = NSCache<NSURL, UIImage>()
    private var posterLoads: [URL: Task<UIImage?, Never>] = [:]
    private var heroes: [URL: UIImage] = [:]
    /// Least recently used first.
    private var heroOrder: [URL] = []
    private var heroLoads: [URL: Task<UIImage?, Never>] = [:]
    private let heroBytes = NSCache<NSURL, NSData>()

    /// Hero prefetches are a guess, so they don't spend cellular data or ignore Low Data Mode.
    private let prefetchSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: config)
    }()

    private init() {
        posters.totalCostLimit = 150 << 20
        heroBytes.totalCostLimit = 60 << 20
    }

    // MARK: Posters

    func cached(_ url: URL) -> UIImage? { posters.object(forKey: url as NSURL) }

    /// Downloads and decodes off the main thread; concurrent requests for one URL share a load.
    func image(for url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        let load = posterLoads[url] ?? Task.detached(priority: .userInitiated) {
            await Self.fetch(url, session: .shared).flatMap { Self.decode($0, maxPixelSize: Self.posterPixels) }
        }
        posterLoads[url] = load
        let image = await load.value
        posterLoads[url] = nil
        if let image { posters.setObject(image, forKey: url as NSURL, cost: Self.cost(image)) }
        return image
    }

    func prefetch(_ urls: some Sequence<URL?>) {
        for case let url? in urls where cached(url) == nil && posterLoads[url] == nil {
            Task { _ = await image(for: url) }
        }
    }

    // MARK: Heroes

    /// The hero if it's decoded and ready to show.
    func hero(_ url: URL) -> UIImage? {
        guard let image = heroes[url] else { return nil }
        touch(url)
        return image
    }

    /// Loads a hero that wasn't ready: from kept bytes if there are any, otherwise downloads it.
    func loadHero(_ url: URL) async -> UIImage? {
        await loadHero(url, session: .shared)
    }

    /// Fetches and decodes a tile's hero in the background, over Wi-Fi only.
    func prefetchHero(_ url: URL?) {
        guard let url else { return }
        if heroes[url] != nil { return touch(url) }
        if heroLoads[url] == nil { Task { _ = await loadHero(url, session: prefetchSession) } }
    }

    private func loadHero(_ url: URL, session: URLSession) async -> UIImage? {
        if let image = hero(url) { return image }
        // An earlier prefetch may still be running, or have been refused on cellular.
        if let running = heroLoads[url], let image = await running.value { return image }
        let kept = heroBytes.object(forKey: url as NSURL) as Data?
        let priority: TaskPriority = session === URLSession.shared ? .userInitiated : .utility
        let load = Task<UIImage?, Never> {
            let result = await Task.detached(priority: priority) { () -> (Data, UIImage)? in
                var bytes = kept
                if bytes == nil { bytes = await Self.fetch(url, session: session) }
                guard let bytes, let image = Self.decode(bytes, maxPixelSize: Self.heroPixels) else { return nil }
                return (bytes, image)
            }.value
            self.heroLoads[url] = nil
            guard let (bytes, decoded) = result else { return nil }
            self.heroBytes.setObject(bytes as NSData, forKey: url as NSURL, cost: bytes.count)
            self.heroes[url] = decoded
            self.touch(url)
            while self.heroOrder.count > Self.heroLimit { self.heroes[self.heroOrder.removeFirst()] = nil }
            return decoded
        }
        heroLoads[url] = load
        return await load.value
    }

    private func touch(_ url: URL) {
        heroOrder.removeAll { $0 == url }
        heroOrder.append(url)
    }

    // MARK: Loading

    nonisolated private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { return nil }
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

    nonisolated private static func cost(_ image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }
}

extension View {
    /// When this item appears, starts loading the posters of the next few in its list, so they're
    /// ready by the time they scroll into view.
    func prefetchPosters(after index: Int, in urls: [URL?], count: Int = 8) -> some View {
        onAppear { ImageCache.shared.prefetch(urls.dropFirst(index + 1).prefix(count)) }
    }
}
