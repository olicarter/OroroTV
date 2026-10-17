import Foundation
import Security
import SwiftUI

enum Keychain {
    private static let service = "dev.olicarter.ororotv"

    static func save(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

/// Saved playback positions and "continue watching", stored locally.
struct ProgressEntry: Codable, Hashable {
    let request: PlaybackRequest
    var position: Double
    var duration: Double
    var updated: Date
    var fraction: Double { duration > 0 ? position / duration : 0 }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var api: OroroAPI?
    @Published var shows: [CatalogItem] = []
    @Published var movies: [CatalogItem] = []
    @Published var catalogError: String?
    @Published var isLoadingCatalog = false
    @Published private(set) var progress: [String: ProgressEntry] = [:]
    @Published var subtitleLanguage = UserDefaults.standard.string(forKey: "subtitleLanguage") ?? "en" {
        didSet { UserDefaults.standard.set(subtitleLanguage, forKey: "subtitleLanguage") }
    }

    private let progressKey = "playbackProgress"

    init() {
        if let email = Keychain.load("email"), let password = Keychain.load("password") {
            api = OroroAPI(email: email, password: password)
        }
        if let data = UserDefaults.standard.data(forKey: progressKey),
           let saved = try? JSONDecoder().decode([String: ProgressEntry].self, from: data) {
            progress = saved
        }
    }

    // MARK: Auth

    func signIn(email: String, password: String) async throws {
        let client = OroroAPI(email: email, password: password)
        try await client.verify()
        Keychain.save(email, for: "email")
        Keychain.save(password, for: "password")
        api = client
    }

    func signOut() {
        Keychain.delete("email")
        Keychain.delete("password")
        OroroAPI.clearCache()
        api = nil
        shows = []
        movies = []
    }

    // MARK: Catalog

    func loadCatalog() async {
        guard let api, shows.isEmpty || movies.isEmpty else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            async let s = api.shows()
            async let m = api.movies()
            (shows, movies) = try await (s, m)
            catalogError = nil
        } catch APIError.unauthorized {
            signOut()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    func search(_ query: String) -> [CatalogItem] {
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return [] }
        let matches = (shows + movies).filter {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
        // Prefix matches first, then by rating.
        return matches.sorted { a, b in
            let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return (a.imdbRating ?? 0) > (b.imdbRating ?? 0)
        }
    }

    var genres: [String] {
        let counts = Dictionary((shows + movies).flatMap(\.genres).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.filter { $0.value >= 20 }.keys.sorted()
    }

    // MARK: Progress

    var continueWatching: [ProgressEntry] {
        progress.values
            .filter { $0.position > 30 && $0.fraction < 0.95 }
            .sorted { $0.updated > $1.updated }
    }

    func savedPosition(for key: String) -> Double? {
        guard let entry = progress[key], entry.fraction < 0.95, entry.position > 10 else { return nil }
        return entry.position
    }

    func fraction(for key: String) -> Double? { progress[key]?.fraction }

    func record(_ data: PlaybackRequest, position: Double, duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        progress[data.progressKey] = ProgressEntry(request: data, position: position, duration: duration, updated: .now)
        if let encoded = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(encoded, forKey: progressKey)
        }
    }
}
