import SwiftUI

struct Backdrop: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.black
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85), .black],
                                startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
    }
}

struct MetaLine: View {
    let year: String?
    let rating: Double?
    let genres: [String]
    var extra: String? = nil

    var body: some View {
        HStack(spacing: 18) {
            if let year { Text(year) }
            if let rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
            if let extra { Text(extra) }
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Movie

struct MovieDetailView: View {
    let item: CatalogItem
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: PlaybackRouter

    private var request: PlaybackRequest {
        PlaybackRequest(kind: .movie, id: item.id, title: item.name, subtitle: item.year, posterThumb: item.posterThumb)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Backdrop(url: item.backdropURL ?? item.posterURL)
            HStack(alignment: .bottom, spacing: 60) {
                PosterImage(url: item.posterURL, title: item.name)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 24) {
                    Text(item.name).font(.largeTitle).bold()
                    MetaLine(year: item.year, rating: item.imdbRating, genres: item.genres,
                             extra: item.length.map { "\($0) min" })
                    if let desc = item.desc {
                        Text(desc).font(.body).lineLimit(5).frame(maxWidth: 1100, alignment: .leading)
                    }
                    PlayButtons(request: request)
                }
            }
            .padding(80)
        }
    }
}

struct PlayButtons: View {
    let request: PlaybackRequest
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: PlaybackRouter

    var body: some View {
        HStack(spacing: 30) {
            if let pos = model.savedPosition(for: request.progressKey) {
                Button { router.play(request) } label: {
                    Label("Resume from \(Duration.seconds(pos).formatted(.time(pattern: .hourMinuteSecond)))", systemImage: "play.fill")
                }
                Button {
                    model.record(request, position: 0, duration: 1)
                    router.play(request)
                } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                }
            } else {
                Button { router.play(request) } label: { Label("Play", systemImage: "play.fill") }
            }
        }
    }
}

// MARK: - Show

struct ShowDetailView: View {
    let item: CatalogItem
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: PlaybackRouter
    @State private var detail: ShowDetail?
    @State private var season: Int = 1
    @State private var error: String?

    var body: some View {
        ZStack {
            Backdrop(url: item.backdropURL ?? item.posterURL)
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    header
                    if let detail {
                        seasonPicker(detail)
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(detail.episodes(in: season)) { ep in
                                EpisodeRow(episode: ep, request: request(for: ep))
                            }
                        }
                        .focusSection()
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(item.name).font(.largeTitle).bold()
            MetaLine(year: item.year, rating: item.imdbRating, genres: item.genres,
                     extra: detail.map { "\($0.seasons.count) season\($0.seasons.count == 1 ? "" : "s")" })
            if let desc = detail?.desc ?? item.desc {
                Text(desc).lineLimit(4).frame(maxWidth: 1200, alignment: .leading)
            }
            if let detail, let next = nextEpisode(detail) {
                Button { router.play(request(for: next)) } label: {
                    Label(model.fraction(for: request(for: next).progressKey) ?? 0 > 0
                          ? "Resume \(next.code)" : "Play \(next.code)", systemImage: "play.fill")
                }
                .focusSection()
            }
        }
    }

    private func seasonPicker(_ detail: ShowDetail) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(detail.seasons, id: \.self) { s in
                    Button { season = s } label: {
                        Text("Season \(s)")
                            .fontWeight(s == season ? .bold : .regular)
                            .underline(s == season, color: .orange)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func request(for ep: Episode) -> PlaybackRequest {
        PlaybackRequest(kind: .show, id: ep.id, title: item.name,
                        subtitle: "\(ep.code)\(ep.name.map { " · \($0)" } ?? "")",
                        parentID: item.id, posterThumb: item.posterThumb)
    }

    /// First episode that's in progress or unwatched, after the latest one touched.
    private func nextEpisode(_ detail: ShowDetail) -> Episode? {
        let ordered = detail.seasons.flatMap { detail.episodes(in: $0) }
        guard let lastTouched = ordered.lastIndex(where: { model.fraction(for: request(for: $0).progressKey) != nil }) else {
            return ordered.first
        }
        let ep = ordered[lastTouched]
        if (model.fraction(for: request(for: ep).progressKey) ?? 0) < 0.95 { return ep }
        return ordered.indices.contains(lastTouched + 1) ? ordered[lastTouched + 1] : ep
    }

    private func load() async {
        guard detail == nil, let api = model.api else { return }
        do {
            let d = try await api.show(item.id)
            detail = d
            season = nextEpisode(d)?.season ?? d.seasons.first ?? 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let request: PlaybackRequest
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var router: PlaybackRouter

    var body: some View {
        Button { router.play(request) } label: {
            HStack(alignment: .top, spacing: 30) {
                Text(episode.number)
                    .font(.title2).bold()
                    .frame(width: 70)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(episode.name ?? "Episode \(episode.number)").font(.headline)
                        Spacer()
                        if let air = episode.airdate { Text(air).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let plot = episode.plot, !plot.isEmpty {
                        Text(plot.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let f = model.fraction(for: request.progressKey), f > 0 {
                        ProgressBar(fraction: f).frame(width: 300)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
    }
}
