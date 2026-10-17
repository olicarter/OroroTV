import SwiftUI

// MARK: - Building blocks

struct PosterCard: View {
    let item: CatalogItem
    var progress: Double? = nil
    /// `nil` fills the width offered (grid columns); shelves use the fixed poster width.
    var width: CGFloat? = PosterImage.size.width

    var body: some View {
        NavigationLink(value: item) {
            PosterImage(url: item.posterURL, title: item.name, width: width)
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 { ProgressBar(fraction: progress).padding(10) }
                }
        }
        .cardButtonStyle()
        .accessibilityLabel(item.name)
    }
}

struct PosterImage: View {
    let url: URL?
    let title: String
    /// `nil` fills the width offered at the poster's aspect ratio.
    var width: CGFloat? = Self.size.width
    static let size = Metrics.poster

    var body: some View {
        let canvas = Color.clear
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [.gray.opacity(0.35), .gray.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                            Text(title).font(.caption).multilineTextAlignment(.center).padding()
                        }
                    }
                }
            }
            .clipped()
        if let width {
            canvas.frame(width: width, height: width * Self.size.height / Self.size.width)
        } else {
            canvas.aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        }
    }
}

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.6))
                Capsule().fill(.orange).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

struct Shelf: View {
    let title: String
    let items: [CatalogItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3).bold()
            ScrollView(.horizontal) {
                LazyHStack(spacing: Metrics.shelfSpacing) {
                    ForEach(items) { PosterCard(item: $0) }
                }
                .padding(.vertical, Metrics.shelfInset)
            }
            .scrollClipDisabled()
        }
    }
}

struct LoadingOrError: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let error = model.catalogError {
            VStack(spacing: 20) {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.loadCatalog() } }
            }
        } else {
            ProgressView("Loading catalog…")
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.shows.isEmpty && model.movies.isEmpty {
            LoadingOrError()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 40) {
                    if !model.continueWatching.isEmpty { ContinueWatchingShelf() }
                    Shelf(title: "Popular shows", items: Array(model.shows.sorted { ($0.userPopularity ?? 0) > ($1.userPopularity ?? 0) }.prefix(30)))
                    Shelf(title: "New episodes", items: Array(model.shows.sorted { $0.sortDate > $1.sortDate }.prefix(30)))
                    Shelf(title: "Recently added movies", items: Array(model.movies.sorted { $0.sortDate > $1.sortDate }.prefix(30)))
                    Shelf(title: "Top rated shows", items: Array(model.shows.sorted { ($0.imdbRating ?? 0) > ($1.imdbRating ?? 0) }.prefix(30)))
                    Shelf(title: "Top rated movies", items: Array(model.movies.sorted { ($0.imdbRating ?? 0) > ($1.imdbRating ?? 0) }.prefix(30)))
                }
                .padding(.horizontal, Metrics.margin)
            }
        }
    }
}

struct ContinueWatchingShelf: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: PlaybackRouter

    /// Falls back to the catalog when the saved entry has no poster (e.g. started from a deep link).
    private func poster(for request: PlaybackRequest) -> URL? {
        if let thumb = request.posterThumb { return URL(string: thumb) }
        let list = request.kind == .show ? model.shows : model.movies
        let match = list.first { $0.id == (request.kind == .show ? request.parentID : request.id) }
            ?? list.first { $0.name == request.title }
        return match?.posterURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Continue watching").font(.title3).bold()
            ScrollView(.horizontal) {
                LazyHStack(spacing: Metrics.shelfSpacing) {
                    ForEach(model.continueWatching, id: \.request) { entry in
                        Button { router.play(entry.request) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                PosterImage(url: poster(for: entry.request), title: entry.request.title)
                                    .frame(width: PosterImage.size.width, height: PosterImage.size.height * 5 / 6)
                                    .clipped()
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.request.title).font(.caption).bold().lineLimit(1)
                                    Text(entry.request.subtitle ?? "Movie").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    ProgressBar(fraction: entry.fraction)
                                }
                                .padding(12)
                                .frame(width: PosterImage.size.width, alignment: .leading)
                            }
                        }
                        .cardButtonStyle()
                        .contextMenu {
                            if let parent = entry.request.parentID {
                                NavigationLink("Go to show", value: ShowLink(id: parent, title: entry.request.title, posterThumb: entry.request.posterThumb))
                            }
                        }
                    }
                }
                .padding(.vertical, Metrics.shelfInset)
            }
            .scrollClipDisabled()
        }
    }
}

// MARK: - Shows / Movies

enum SortOrder: String, CaseIterable, Identifiable {
    case popular = "Popular", recent = "Recent", rating = "Rating", name = "A–Z"
    var id: Self { self }
}

struct CatalogView: View {
    let kind: MediaKind
    @EnvironmentObject var model: AppModel
    @State private var genre: String?
    @State private var sort: SortOrder = .recent

    private var source: [CatalogItem] { kind == .show ? model.shows : model.movies }

    private var items: [CatalogItem] {
        var list = source
        if let genre { list = list.filter { $0.genres.contains(genre) } }
        switch sort {
        case .popular: list.sort { ($0.userPopularity ?? 0, $0.sortDate) > ($1.userPopularity ?? 0, $1.sortDate) }
        case .recent: list.sort { $0.sortDate > $1.sortDate }
        case .rating: list.sort { ($0.imdbRating ?? 0) > ($1.imdbRating ?? 0) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    private var sorts: [SortOrder] { kind == .show ? SortOrder.allCases : SortOrder.allCases.filter { $0 != .popular } }

    var body: some View {
        if source.isEmpty {
            LoadingOrError()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    #if os(tvOS)
                    HStack(spacing: 30) {
                        Picker("Sort", selection: $sort) {
                            ForEach(sorts) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 700)

                        Menu {
                            Button("All genres") { genre = nil }
                            ForEach(model.genres, id: \.self) { g in Button(g) { genre = g } }
                        } label: {
                            Label(genre ?? "All genres", systemImage: "line.3.horizontal.decrease")
                        }
                        Spacer()
                        Text("\(items.count) titles").foregroundStyle(.secondary)
                    }
                    .focusSection()
                    #else
                    Text("\(items.count) titles\(genre.map { " · \($0)" } ?? "")").foregroundStyle(.secondary)
                    #endif

                    LazyVGrid(columns: Metrics.gridColumns, spacing: Metrics.gridSpacing) {
                        ForEach(items) { PosterCard(item: $0, width: nil) }
                    }
                    .tvFocusSection()
                }
                .padding(.horizontal, Metrics.margin)
            }
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(sorts) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Genre", selection: $genre) {
                            Text("All genres").tag(String?.none)
                            ForEach(model.genres, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.menu)
                    } label: {
                        Label("Sort and filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            #endif
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: PlaybackRouter

    var body: some View {
        let query = router.searchQuery
        let results = model.search(query)
        ScrollView {
            if query.isEmpty {
                Text("Search shows and movies by title")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if results.isEmpty {
                Text("No results for “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: Metrics.gridColumns, spacing: Metrics.gridSpacing) {
                    ForEach(results.prefix(120)) { item in
                        VStack(spacing: 14) {
                            PosterCard(item: item, width: nil)
                            Text(item.name).font(.caption).lineLimit(1)
                            Text("\(item.kind == .show ? "Show" : "Movie") · \(item.year ?? "")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, Metrics.margin)
            }
        }
        .searchable(text: $router.searchQuery, prompt: "Shows and movies")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    private let languages = ["en", "ru", "es", "it", "pl", "pt", "tr", "fr", "de", "cs", "uk"]

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Default subtitles", selection: $model.subtitleLanguage) {
                    Text("Off").tag("off")
                    ForEach(languages, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
            }
            Section("Library") {
                Button("Refresh catalog") {
                    OroroAPI.clearCache()
                    model.shows = []
                    model.movies = []
                    Task { await model.loadCatalog() }
                }
            }
            Section("Account") {
                Button("Sign out", role: .destructive) { model.signOut() }
            }
        }
        .frame(maxWidth: 1000)
    }
}
