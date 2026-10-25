#if !os(tvOS)
import Foundation
import Network

/// A tiny HTTP server on the phone's Wi-Fi address that serves a `SubtitledStream`'s playlists,
/// so an Apple TV playing over AirPlay gets ororo's subtitles too. Only the playlists come from
/// here; the video, audio and VTT files load straight from ororo.tv.
///
/// Paths start with a random token, so other devices on the network can't fetch the signed stream URLs.
final class PlaylistServer {
    private let stream: SubtitledStream
    private let listener: NWListener
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "dev.olicarter.ororotv.playlist-server")

    init?(stream: SubtitledStream) {
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
        self.stream = stream
        self.listener = listener
    }

    deinit { listener.cancel() }

    /// Starts listening and returns the master playlist's URL, or nil without a Wi-Fi address.
    func start() async -> URL? {
        guard let host = Self.wifiAddress() else { return nil }
        let port: UInt16? = await withCheckedContinuation { continuation in
            // Runs on `queue`; clearing the handler makes sure it resumes once.
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue)
                case .failed, .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: nil)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        guard let port else { return nil }
        return URL(string: "http://\(host):\(port)/\(token)/master.m3u8")
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let header = String(data: buffer, encoding: .utf8), header.contains("\r\n\r\n") else {
                if isComplete || error != nil || buffer.count > 65_536 { connection.cancel() }
                else { self.receiveRequest(on: connection, buffer: buffer) }
                return
            }
            // "GET /<token>/master.m3u8 HTTP/1.1"
            let parts = header.prefix { $0 != "\r" }.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
            Task { await self.respond(on: connection, method: method, path: path) }
        }
    }

    private func respond(on connection: NWConnection, method: String, path: String) async {
        let prefix = "/\(token)/"
        var status = "404 Not Found"
        var body = Data()
        // Subtitle renditions are listed as "/<token>/subtitles/…", relative to this server.
        if path.hasPrefix(prefix), method == "GET" || method == "HEAD",
           let text = try? await stream.playlist(at: String(path.dropFirst(prefix.count)), base: prefix) {
            status = "200 OK"
            body = Data(text.utf8)
        }
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/vnd.apple.mpegurl\r\nCache-Control: no-store\r\n" }
        var response = Data((head + "\r\n").utf8)
        if method != "HEAD" { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The IPv4 address of the Wi-Fi interface, which is what the Apple TV can reach.
    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: ifa.pointee.ifa_name) == "en0",
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
#endif
