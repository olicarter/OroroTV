import SwiftUI
import UIKit

/// Decoded poster images kept in memory, so a poster that has already loaded, or was prefetched
/// before scrolling into view, shows straight away instead of fading in.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var loads: [URL: Task<UIImage?, Never>] = [:]

    private init() { cache.countLimit = 500 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// Downloads and decodes off the main thread; concurrent requests for one URL share a load.
    func image(for url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        let load = loads[url] ?? Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        loads[url] = load
        let image = await load.value
        loads[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    func prefetch(_ urls: some Sequence<URL?>) {
        for case let url? in urls where cached(url) == nil && loads[url] == nil {
            Task { _ = await image(for: url) }
        }
    }
}

extension View {
    /// When this item appears, starts loading the posters of the next few in its list, so they're
    /// ready by the time they scroll into view.
    func prefetchPosters(after index: Int, in urls: [URL?], count: Int = 8) -> some View {
        onAppear { ImageCache.shared.prefetch(urls.dropFirst(index + 1).prefix(count)) }
    }
}
