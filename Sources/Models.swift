import Foundation

enum MediaKind: String, Codable, Hashable {
    case show, movie
}

/// A row in the `/api/v2/shows` or `/api/v2/movies` catalog.
struct CatalogItem: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let year: String?
    let desc: String?
    let imdbRating: Double?
    let arrayGenres: [String]?
    let backdropUrl: String?
    let posterThumb: String?
    let updatedAt: Int?
    let newestVideo: Int?
    let userPopularity: Int?
    let length: Int?
    var kind: MediaKind = .show

    enum CodingKeys: String, CodingKey {
        case id, name, year, desc, length
        case imdbRating = "imdb_rating"
        case arrayGenres = "array_genres"
        case backdropUrl = "backdrop_url"
        case posterThumb = "poster_thumb"
        case updatedAt = "updated_at"
        case newestVideo = "newest_video"
        case userPopularity = "user_popularity"
    }

    var posterURL: URL? { posterThumb.flatMap(URL.init(string:)) }
    var backdropURL: URL? { backdropUrl.flatMap(URL.init(string:)) }
    /// The detail page's background.
    var heroURL: URL? { backdropURL ?? posterURL }
    var genres: [String] { arrayGenres ?? [] }
    var sortDate: Int { newestVideo ?? updatedAt ?? 0 }
}

struct ShowsResponse: Decodable { let shows: [CatalogItem] }
struct MoviesResponse: Decodable { let movies: [CatalogItem] }

struct ShowDetail: Decodable {
    let id: Int
    let name: String
    let desc: String?
    let year: String?
    let imdbRating: Double?
    let backdropUrl: String?
    let posterThumb: String?
    let arrayGenres: [String]?
    let episodes: [Episode]

    enum CodingKeys: String, CodingKey {
        case id, name, desc, year, episodes
        case imdbRating = "imdb_rating"
        case backdropUrl = "backdrop_url"
        case posterThumb = "poster_thumb"
        case arrayGenres = "array_genres"
    }

    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }

    func episodes(in season: Int) -> [Episode] {
        episodes.filter { $0.season == season }
            .sorted { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
    }
}

struct Episode: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let plot: String?
    let season: Int
    let number: String
    let airdate: String?

    var code: String { String(format: "S%02dE%02d", season, Int(number) ?? 0) }
}

struct Subtitle: Decodable, Hashable {
    let lang: String
    let url: String
}

/// Playback info returned by `/api/v2/episodes/:id` and `/api/v2/movies/:id`.
struct Playable: Decodable {
    let id: Int
    let name: String?
    let url: String
    let subtitles: [Subtitle]?
    let showName: String?
    let season: Int?
    let number: String?
    let plot: String?
    let desc: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, subtitles, season, number, plot, desc
        case showName = "show_name"
    }
}

/// What the player needs to start, plus where to store progress.
struct PlaybackRequest: Codable, Identifiable, Hashable {
    let kind: MediaKind
    let id: Int
    let title: String
    let subtitle: String?
    /// Show id for episodes, so "continue watching" can link back to the show.
    var parentID: Int? = nil
    var posterThumb: String? = nil
    var progressKey: String { "\(kind.rawValue)-\(id)" }
}
