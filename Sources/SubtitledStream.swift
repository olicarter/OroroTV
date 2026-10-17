import AVFoundation

/// Adds ororo's external WebVTT files to its HLS stream as subtitle renditions, so AVKit lists
/// them in its own subtitles menu and draws them itself (Picture in Picture included).
///
/// The asset's URL uses a private scheme, so AVFoundation asks this delegate for it. We fetch the
/// real master playlist and add a SUBTITLES group with one rendition per language; each rendition
/// is a one-segment playlist whose segment is the language's VTT file on ororo.tv (AVFoundation
/// only loads media segments over HTTP). Variant and audio playlists are made absolute and load
/// directly.
final class SubtitledStream: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "ororo-hls"
    private static let subtitlesHost = "subtitles"
    private static let groupID = "subs"

    let asset: AVURLAsset
    private let master: URL
    private let subtitles: [Subtitle]
    private let queue = DispatchQueue(label: "dev.olicarter.ororotv.subtitled-stream")
    /// Length of the video, needed for the subtitle playlists; read from the first variant.
    private var firstVariant: URL?

    init(url: URL, subtitles: [Subtitle]) {
        master = url
        self.subtitles = subtitles
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        asset = AVURLAsset(url: components.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }
        Task {
            do {
                let (data, type) = try await response(for: url)
                loadingRequest.contentInformationRequest?.contentType = type
                loadingRequest.contentInformationRequest?.contentLength = Int64(data.count)
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
                loadingRequest.dataRequest?.respond(with: data)
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    private func response(for url: URL) async throws -> (Data, String) {
        guard url.host == Self.subtitlesHost else {
            return (Data(try await rewrittenMaster().utf8), "public.m3u-playlist")
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard let index = Int(name), subtitles.indices.contains(index) else { throw URLError(.fileDoesNotExist) }
        return (Data(try await subtitlePlaylist(index).utf8), "public.m3u-playlist")
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        return String(decoding: data, as: UTF8.self)
    }

    private func rewrittenMaster() async throws -> String {
        let text = try await fetchText(master)
        let absolute = { (uri: String) in URL(string: uri, relativeTo: self.master)?.absoluteString ?? uri }
        var names = Set<String>()
        let renditions = subtitles.enumerated().map { index, sub in
            var name = Languages.name(sub.lang)
            while !names.insert(name).inserted { name += " (\(index + 1))" }
            return "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(Self.groupID)\",LANGUAGE=\"\(sub.lang)\",NAME=\"\(name)\","
                + "AUTOSELECT=YES,DEFAULT=NO,URI=\"\(Self.scheme)://\(Self.subtitlesHost)/\(index).m3u8\""
        }

        var out: [String] = []
        var addedRenditions = false
        var nextIsVariant = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                if !addedRenditions && !renditions.isEmpty {
                    out += renditions
                    addedRenditions = true
                }
                if !renditions.isEmpty { line += ",SUBTITLES=\"\(Self.groupID)\"" }
                nextIsVariant = true
            } else if line.hasPrefix("#"), let range = line.range(of: #"URI="[^"]*""#, options: .regularExpression) {
                let uri = String(line[range].dropFirst(5).dropLast())
                line.replaceSubrange(range, with: "URI=\"\(absolute(uri))\"")
            } else if !line.hasPrefix("#") {
                line = absolute(line)
                if nextIsVariant, firstVariant == nil { firstVariant = URL(string: line) }
                nextIsVariant = false
            }
            out.append(line)
        }
        return out.joined(separator: "\n") + "\n"
    }

    private func subtitlePlaylist(_ index: Int) async throws -> String {
        var duration = 4 * 3600.0
        if let firstVariant, let playlist = try? await fetchText(firstVariant) {
            let total = playlist.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("#EXTINF:") }
                .compactMap { Double($0.dropFirst(8).prefix { $0 != "," }) }
                .reduce(0, +)
            if total > 0 { duration = total }
        }
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(String(format: "%.3f", duration)),
        \(subtitles[index].url)
        #EXT-X-ENDLIST

        """
    }
}
