import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your email or password was not accepted, or your subscription has expired."
        case .http(let code): "Ororo returned an error (HTTP \(code))."
        }
    }
}

/// Thin client for ororo.tv's JSON API (the same one the site and its official
/// TV apps use). Auth is HTTP Basic with the account's email and password.
final class OroroAPI {
    static let base = URL(string: "https://ororo.tv/api/v2/")!

    private let session: URLSession
    private let authHeader: String

    init(email: String, password: String) {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        authHeader = "Basic " + Data("\(email):\(password)".utf8).base64EncodedString()
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: await getData(path))
    }

    private func getData(_ path: String) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("OroroTV-tvOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 402 || status == 403 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        return data
    }

    /// Cheap call used to validate credentials at sign-in.
    func verify() async throws {
        _ = try await getData("shows/1370")
    }

    func shows() async throws -> [CatalogItem] {
        try await cached("shows.json") { try await self.getData("shows") }
            .decode(ShowsResponse.self).shows.map { var s = $0; s.kind = .show; return s }
    }

    func movies() async throws -> [CatalogItem] {
        try await cached("movies.json") { try await self.getData("movies") }
            .decode(MoviesResponse.self).movies.map { var m = $0; m.kind = .movie; return m }
    }

    func show(_ id: Int) async throws -> ShowDetail { try await get("shows/\(id)", as: ShowDetail.self) }
    func episode(_ id: Int) async throws -> Playable { try await get("episodes/\(id)", as: Playable.self) }
    func movie(_ id: Int) async throws -> Playable { try await get("movies/\(id)", as: Playable.self) }

    func playable(for request: PlaybackRequest) async throws -> Playable {
        switch request.kind {
        case .show: try await episode(request.id)
        case .movie: try await movie(request.id)
        }
    }

    // The catalogs are several MB each, so keep a disk copy and refresh it at most every few hours.
    private func cached(_ name: String, maxAge: TimeInterval = 6 * 3600, fetch: () async throws -> Data) async throws -> Data {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let file = dir.appendingPathComponent(name)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           let data = try? Data(contentsOf: file) {
            return data
        }
        let data = try await fetch()
        try? data.write(to: file)
        return data
    }

    static func clearCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["shows.json", "movies.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

private extension Data {
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: self) }
}
