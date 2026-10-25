import AVKit
import Combine
import SwiftUI

// MARK: - WebVTT

struct Cue {
    let start: Double
    let end: Double
    let text: String
}

enum WebVTT {
    static func parse(_ source: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { continue }
            let text = lines[(timingIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(Cue(start: start, end: end, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func time(_ raw: String) -> Double? {
        let comps = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        let nums = comps.compactMap { Double($0) }
        guard nums.count == comps.count, (2...3).contains(nums.count) else { return nil }
        return nums.reduce(0) { $0 * 60 + $1 }
    }
}

// MARK: - Player

/// Owns the AVPlayer, the subtitle track and progress reporting for one playback session.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    let player = AVPlayer()
    @Published var currentCue: String?
    @Published var error: String?
    @Published var subtitles: [Subtitle] = []
    @Published var selectedLanguage: String?

    private var cues: [Cue] = []
    #if !os(tvOS)
    /// Serves the stream with ororo's subtitles added; must outlive the player item.
    private var stream: SubtitledStream?
    /// The same playlists over HTTP, for an Apple TV playing over AirPlay.
    private var server: PlaylistServer?
    private var airPlayURL: URL?
    private var directURL: URL?
    private var playingAirPlayItem = false
    private var itemMetadata: [AVMetadataItem] = []
    private var selectionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var externalObservation: NSKeyValueObservation?
    private var failureObservation: NSKeyValueObservation?
    #endif
    private var timeObserver: Any?
    private var lastSaved: Double = 0
    private let request: PlaybackRequest
    private weak var model: AppModel?

    init(request: PlaybackRequest, model: AppModel) {
        self.request = request
        self.model = model
        super.init()
    }

    func start() async {
        guard let api = model?.api else { return }
        do {
            let playable = try await api.playable(for: request)
            guard let url = URL(string: playable.url) else { throw APIError.http(0) }
            subtitles = (playable.subtitles ?? []).sorted { $0.lang < $1.lang }
            #if os(tvOS)
            let item = AVPlayerItem(url: url)
            item.externalMetadata = metadata(playable)
            #else
            stream = SubtitledStream(url: url, subtitles: subtitles)
            directURL = url
            server = stream.flatMap(PlaylistServer.init)
            airPlayURL = await server?.start()
            itemMetadata = metadata(playable)
            playingAirPlayItem = isAirPlaying
            let item = makeItem()
            #endif
            player.replaceCurrentItem(with: item)
            if let resume = model?.savedPosition(for: request.progressKey) {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            observeTime()
            #if !os(tvOS)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            player.play()

            let preferred = model?.subtitleLanguage ?? "en"
            #if os(tvOS)
            if preferred != "off", let sub = subtitles.first(where: { $0.lang == preferred }) {
                await selectSubtitle(sub)
            }
            #else
            await selectMedia(subtitles: preferred, in: item)
            observeRoute()
            #endif
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectSubtitle(_ subtitle: Subtitle?) async {
        selectedLanguage = subtitle?.lang
        cues = []
        currentCue = nil
        guard let subtitle, let url = URL(string: subtitle.url) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if selectedLanguage == subtitle.lang { cues = WebVTT.parse(text) }
        } catch {
            cues = []
        }
    }

    #if !os(tvOS)
    /// AirPlay video, or AirPlay audio about to become it.
    private var isAirPlaying: Bool {
        player.isExternalPlaybackActive
            || AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    /// The private-scheme stream on this device. Over AirPlay the Apple TV loads the stream
    /// itself and can't use that scheme, so it gets the HTTP copy (or, failing that, ororo's
    /// own playlist without subtitles).
    private func makeItem() -> AVPlayerItem {
        failureObservation = nil
        let item = playingAirPlayItem
            ? AVPlayerItem(url: airPlayURL ?? directURL!)
            : AVPlayerItem(asset: stream!.asset)
        item.externalMetadata = itemMetadata
        if playingAirPlayItem, airPlayURL != nil {
            failureObservation = item.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    guard let self, self.player.currentItem === item else { return }
                    self.airPlayURL = nil
                    await self.replaceItem()
                }
            }
        }
        return item
    }

    private func observeRoute() {
        externalObservation = player.observe(\.isExternalPlaybackActive) { [weak self] _, _ in
            Task { @MainActor in await self?.routeChanged() }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.routeChanged() }
        }
    }

    private func routeChanged() async {
        guard stream != nil, isAirPlaying != playingAirPlayItem else { return }
        playingAirPlayItem = isAirPlaying
        await replaceItem()
    }

    /// Swaps in the item for the current route, carrying over the position and subtitles.
    private func replaceItem() async {
        let time = player.currentTime()
        let item = makeItem()
        player.replaceCurrentItem(with: item)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        await selectMedia(subtitles: model?.subtitleLanguage ?? "en", in: item)
    }

    /// Makes sure an audio track is playing, picks the saved language in AVKit's subtitles menu,
    /// then remembers whatever the viewer chooses there as the new default.
    private func selectMedia(subtitles language: String, in item: AVPlayerItem) async {
        // Ororo's audio renditions aren't marked DEFAULT or AUTOSELECT, so iOS can leave the
        // video silent. SubtitledStream marks them; this covers streams it couldn't rewrite.
        if let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible),
           item.currentMediaSelection.selectedMediaOption(in: audio) == nil {
            item.select(audio.defaultOption ?? audio.options.first, in: audio)
        }
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        let option = group.options.first { $0.extendedLanguageTag == language }
        item.select(language == "off" ? nil : option, in: group)
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let chosen = item.currentMediaSelection.selectedMediaOption(in: group)
                self?.model?.subtitleLanguage = chosen?.extendedLanguageTag ?? "off"
            }
        }
    }
    #endif

    func stop() {
        saveProgress()
        #if !os(tvOS)
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        selectionObserver = nil
        routeObserver = nil
        externalObservation = nil
        failureObservation = nil
        server = nil
        stream = nil
        #endif
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = time.seconds
                let cue = self.cues.last(where: { $0.start <= t })
                self.currentCue = (cue.map { t < $0.end } ?? false) ? cue?.text : nil
                if abs(t - self.lastSaved) >= 10 { self.saveProgress() }
            }
        }
    }

    private func saveProgress() {
        guard let item = player.currentItem else { return }
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        lastSaved = position
        model?.record(request, position: position, duration: item.duration.seconds)
    }

    private func metadata(_ playable: Playable) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        return [item(.commonIdentifierTitle, request.title),
                item(.iTunesMetadataTrackSubTitle, request.subtitle),
                item(.commonIdentifierDescription, playable.plot ?? playable.desc)].compactMap { $0 }
    }
}

#if os(tvOS)
/// AVPlayerViewController (native transport bar, scrubbing, Siri remote gestures)
/// with an overlay for the external WebVTT subtitles Ororo serves alongside its HLS streams.
struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var controller: PlayerController
    let languageName: (String) -> String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = controller.player
        let host = UIHostingController(rootView: SubtitleOverlay(controller: controller))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        vc.addChild(host)
        if let overlay = vc.contentOverlayView {
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        host.didMove(toParent: vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        // Subtitle picker lives in the transport bar's info panel.
        let current = controller.selectedLanguage
        var actions = [UIAction(title: "Off", state: current == nil ? .on : .off) { _ in
            Task { await controller.selectSubtitle(nil) }
        }]
        actions += controller.subtitles.map { sub in
            UIAction(title: languageName(sub.lang), state: current == sub.lang ? .on : .off) { _ in
                Task { await controller.selectSubtitle(sub) }
            }
        }
        vc.transportBarCustomMenuItems = controller.subtitles.isEmpty ? [] : [
            UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), options: .singleSelection, children: actions)
        ]
    }
}

struct SubtitleOverlay: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        VStack {
            Spacer()
            if let cue = controller.currentCue {
                Text(cue)
                    .font(.system(size: 46, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 70)
                    .padding(.horizontal, 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct PlayerScreen: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var controller: PlayerController

    init(request: PlaybackRequest, model: AppModel) {
        _controller = StateObject(wrappedValue: PlayerController(request: request, model: model))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerViewControllerRepresentable(controller: controller, languageName: Languages.name)
                .ignoresSafeArea()
            if let error = controller.error {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 80))
                    Text("Couldn't play this video").font(.title2)
                    Text(error).foregroundStyle(.secondary)
                }
            }
        }
        .task { await controller.start() }
        .onDisappear { controller.stop() }
    }
}

#else
/// iPad: AVKit's own full-screen player, presented modally, so the close button, swipe to
/// dismiss, subtitles menu and Picture in Picture are all the system's.
struct NativePlayerPresenter: UIViewControllerRepresentable {
    @Binding var request: PlaybackRequest?
    let model: AppModel

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.dismissRequest = { request = nil }
        context.coordinator.show(request, model: model, from: host)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var dismissRequest: () -> Void = {}
        private var current: (request: PlaybackRequest, controller: PlayerController, view: AVPlayerViewController)?
        private weak var host: UIViewController?
        private var inPictureInPicture = false
        private var errorWatch: AnyCancellable?

        func show(_ request: PlaybackRequest?, model: AppModel, from host: UIViewController) {
            self.host = host
            guard request != current?.request else { return }
            if let current {
                current.view.presentingViewController?.dismiss(animated: true)
                finish(clearRequest: false)
            }
            guard let request else { return }
            let controller = PlayerController(request: request, model: model)
            let vc = AVPlayerViewController()
            vc.player = controller.player
            vc.delegate = self
            vc.modalPresentationStyle = .fullScreen
            vc.canStartPictureInPictureAutomaticallyFromInline = true
            current = (request, controller, vc)
            errorWatch = controller.$error.compactMap { $0 }.sink { [weak self] message in
                self?.showError(message)
            }
            host.present(vc, animated: true)
            Task { await controller.start() }
        }

        private func finish(clearRequest: Bool = true) {
            current?.controller.stop()
            current = nil
            errorWatch = nil
            inPictureInPicture = false
            if clearRequest { dismissRequest() }
        }

        private func showError(_ message: String) {
            guard let vc = current?.view else { return }
            let alert = UIAlertController(title: "Couldn't play this video", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                vc.dismiss(animated: true)
                self.finish()
            })
            vc.present(alert, animated: true)
        }

        // Close button or swipe down. Not the end of playback while it continues in Picture in Picture.
        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { context in
                guard !context.isCancelled, !self.inPictureInPicture else { return }
                self.finish()
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ vc: AVPlayerViewController) { inPictureInPicture = true }

        func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
            inPictureInPicture = false
            // Closed from the PiP window rather than expanded back into the app.
            if vc.presentingViewController == nil { finish() }
        }

        func playerViewController(_ vc: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
            guard let host, vc.presentingViewController == nil else { return completion(true) }
            host.present(vc, animated: true) { completion(true) }
        }
    }
}
#endif

enum Languages {
    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}
