import SwiftUI

@main
struct OroroTVApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.api == nil {
                    LoginView()
                } else {
                    RootView()
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
        }
    }
}

enum AppTab: String, CaseIterable { case home, shows, movies, search, settings }

/// App-wide navigation: selected tab, each tab's stack, the search query and the
/// full-screen player. Also handles `ororotv://` deep links.
@MainActor
final class PlaybackRouter: ObservableObject {
    @Published var current: PlaybackRequest?
    @Published var tab: AppTab = .home
    @Published var paths: [AppTab: NavigationPath] = [:]
    @Published var searchQuery = ""

    init() {
        #if DEBUG
        // Apply a launch deep link's tab before the first frame, so tvOS focus can't override it.
        if let raw = ProcessInfo.processInfo.environment["OROROTV_OPEN_URL"],
           let comps = URLComponents(string: raw) {
            switch comps.host {
            case "search":
                tab = .search
                searchQuery = comps.queryItems?.first { $0.name == "q" }?.value ?? ""
            case "tab":
                tab = AppTab(rawValue: comps.path.trimmingCharacters(in: ["/"])) ?? .home
            default: break
            }
        }
        #endif
    }

    func play(_ request: PlaybackRequest) { current = request }

    /// Pushes onto the current tab rather than switching tabs: on tvOS the focused
    /// tab-bar item owns the selection, so programmatic tab switches can be undone.
    private func push<V: Hashable>(_ value: V) {
        var path = paths[tab] ?? NavigationPath()
        path.append(value)
        paths[tab] = path
    }

    func path(_ tab: AppTab) -> Binding<NavigationPath> {
        Binding { self.paths[tab] ?? NavigationPath() } set: { self.paths[tab] = $0 }
    }

    /// ororotv://show/<id>, ororotv://movie/<id>, ororotv://play/episode/<id>,
    /// ororotv://play/movie/<id>, ororotv://search?q=<text>, ororotv://tab/<name>
    func open(_ url: URL, model: AppModel) async {
        guard url.scheme == "ororotv", let host = url.host() else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        current = nil
        switch (host, parts.first, parts.last.flatMap(Int.init)) {
        case ("tab", let name?, _):
            if let t = AppTab(rawValue: name) { tab = t }
        case ("search", _, _):
            tab = .search
            searchQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value ?? ""
        case ("show", _, let id?):
            await model.loadCatalog()
            push(ShowLink(id: id, title: "", posterThumb: nil))
        case ("movie", _, let id?):
            await model.loadCatalog()
            guard let item = model.movies.first(where: { $0.id == id }) else { return }
            push(item)
        case ("play", "episode", let id?):
            let ep = try? await model.api?.episode(id)
            let code = ep.flatMap { e in e.season.map { String(format: "S%02dE%02d", $0, Int(e.number ?? "") ?? 0) } }
            let show = model.shows.first { $0.name == ep?.showName }
            play(PlaybackRequest(kind: .show, id: id, title: ep?.showName ?? "Episode \(id)",
                                 subtitle: [code, ep?.name].compactMap { $0 }.joined(separator: " · "),
                                 parentID: show?.id, posterThumb: show?.posterThumb))
        case ("play", "movie", let id?):
            let name = model.movies.first { $0.id == id }?.name ?? "Movie \(id)"
            play(PlaybackRequest(kind: .movie, id: id, title: name, subtitle: nil))
        default:
            break
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var router = PlaybackRouter()

    var body: some View {
        tabs
            .environmentObject(router)
            .task {
                await model.loadCatalog()
                #if DEBUG
                // Open a deep link at launch without tvOS's "Open in…?" prompt (simulator testing).
                if let raw = ProcessInfo.processInfo.environment["OROROTV_OPEN_URL"], let url = URL(string: raw) {
                    await router.open(url, model: model)
                }
                #endif
            }
            .onOpenURL { url in Task { await router.open(url, model: model) } }
            .fullScreenCover(item: $router.current) { request in
                PlayerScreen(request: request, model: model).environmentObject(model)
            }
    }

    #if os(tvOS)
    private var tabs: some View {
        TabView(selection: $router.tab) {
            tab(.home) { HomeView() }.tabItem { Label("Home", systemImage: "house") }.tag(AppTab.home)
            tab(.shows) { CatalogView(kind: .show) }.tabItem { Label("Shows", systemImage: "tv") }.tag(AppTab.shows)
            tab(.movies) { CatalogView(kind: .movie) }.tabItem { Label("Movies", systemImage: "film") }.tag(AppTab.movies)
            tab(.search) { SearchView() }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(AppTab.search)
            tab(.settings) { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
    }
    #else
    /// iPadOS tab bar that the user can turn into a sidebar, with Search as the system search tab.
    private var tabs: some View {
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) { tab(.home, "Home") { HomeView() } }
            Tab("Shows", systemImage: "tv", value: AppTab.shows) { tab(.shows, "Shows") { CatalogView(kind: .show) } }
            Tab("Movies", systemImage: "film", value: AppTab.movies) { tab(.movies, "Movies") { CatalogView(kind: .movie) } }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { tab(.settings, "Settings") { SettingsView() } }
            Tab(value: AppTab.search, role: .search) { tab(.search, "Search") { SearchView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(.orange)
    }
    #endif

    private func tab<Content: View>(_ tab: AppTab, _ title: String = "", @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: router.path(tab)) {
            content()
                #if !os(tvOS)
                .navigationTitle(title)
                #endif
                .navigationDestination(for: CatalogItem.self) { item in
                    switch item.kind {
                    case .show: ShowDetailView(item: item)
                    case .movie: MovieDetailView(item: item)
                    }
                }
                .navigationDestination(for: ShowLink.self) { link in
                    ShowDetailView(item: link.item(in: model))
                }
        }
    }
}

/// Navigation value for reaching a show from "continue watching", where we only have its id.
struct ShowLink: Hashable {
    let id: Int
    let title: String
    let posterThumb: String?

    @MainActor
    func item(in model: AppModel) -> CatalogItem {
        model.shows.first { $0.id == id } ?? CatalogItem(
            id: id, name: title, year: nil, desc: nil, imdbRating: nil, arrayGenres: nil,
            backdropUrl: nil, posterThumb: posterThumb, updatedAt: nil, newestVideo: nil,
            userPopularity: nil, length: nil, kind: .show)
    }
}
