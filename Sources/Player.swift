import AVKit
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
    #if !os(tvOS)
    /// Whether our close/subtitles bar is showing; kept roughly in step with AVKit's own controls.
    @Published var chromeVisible = true
    private var hideChrome: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    #endif

    private var cues: [Cue] = []
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
        #if !os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                if playing { self?.scheduleHideChrome() } else { self?.showChrome(autoHide: false) }
            }
        }
        #endif
        do {
            let playable = try await api.playable(for: request)
            guard let url = URL(string: playable.url) else { throw APIError.http(0) }
            let item = AVPlayerItem(url: url)
            item.externalMetadata = metadata(playable)
            player.replaceCurrentItem(with: item)
            if let resume = model?.savedPosition(for: request.progressKey) {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            observeTime()
            player.play()

            subtitles = (playable.subtitles ?? []).sorted { $0.lang < $1.lang }
            let preferred = model?.subtitleLanguage ?? "en"
            if preferred != "off", let sub = subtitles.first(where: { $0.lang == preferred }) {
                await selectSubtitle(sub)
            }
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
    func toggleChrome() {
        if chromeVisible {
            hideChrome?.cancel()
            withAnimation { chromeVisible = false }
        } else {
            showChrome(autoHide: true)
        }
    }

    func showChrome(autoHide: Bool) {
        withAnimation { chromeVisible = true }
        if autoHide { scheduleHideChrome() } else { hideChrome?.cancel() }
    }

    /// AVKit fades its controls a few seconds into playback; follow suit.
    private func scheduleHideChrome() {
        hideChrome?.cancel()
        hideChrome = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.timeControlStatus == .playing else { return }
            withAnimation { chromeVisible = false }
        }
    }
    #endif

    func stop() {
        saveProgress()
        #if !os(tvOS)
        statusObservation = nil
        hideChrome?.cancel()
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

/// AVPlayerViewController (native transport bar, scrubbing, Siri remote gestures on tvOS;
/// Picture in Picture on iPad) with an overlay for the external WebVTT subtitles Ororo
/// serves alongside its HLS streams.
struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var controller: PlayerController
    let languageName: (String) -> String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = controller.player
        #if !os(tvOS)
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        // AVKit toggles its controls on a tap; watch the same taps to toggle our bar with them.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        vc.view.addGestureRecognizer(tap)
        #endif
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
        #if os(tvOS)
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
        #endif
    }

    #if !os(tvOS)
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: PlayerController
        init(controller: PlayerController) { self.controller = controller }

        @objc func tapped() { controller.toggleChrome() }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Taps on AVKit's own buttons and scrubber don't toggle its controls, so ignore them too.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            sequence(first: touch.view, next: { $0?.superview }).allSatisfy { !($0 is UIControl) }
        }
    }
    #endif
}

struct SubtitleOverlay: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        VStack {
            Spacer()
            if let cue = controller.currentCue {
                Text(cue)
                    .font(.system(size: Metrics.subtitleSize, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, Metrics.subtitleSize * 1.5)
                    .padding(.horizontal, Metrics.margin * 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct PlayerScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
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
        #if !os(tvOS)
        // tvOS dismisses with the remote's Menu button and puts subtitles in the transport bar;
        // iPad needs both on screen.
        .overlay(alignment: .top) {
            // Faded rather than removed, so an open subtitles menu survives the auto-hide.
            let visible = controller.chromeVisible || controller.error != nil
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
                Spacer()
                if !controller.subtitles.isEmpty { subtitlesMenu }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(.white)
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 72)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
        }
        .statusBarHidden(!controller.chromeVisible)
        .persistentSystemOverlays(.hidden)
        #endif
        .task { await controller.start() }
        .onDisappear { controller.stop() }
    }
}

#if !os(tvOS)
extension PlayerScreen {
    private var subtitlesMenu: some View {
        Menu {
            Picker("Subtitles", selection: Binding(
                get: { controller.selectedLanguage },
                set: { lang in Task { await controller.selectSubtitle(controller.subtitles.first { $0.lang == lang }) } }
            )) {
                Text("Off").tag(String?.none)
                ForEach(controller.subtitles, id: \.lang) { Text(Languages.name($0.lang)).tag(String?.some($0.lang)) }
            }
        } label: {
            Image(systemName: controller.selectedLanguage == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .accessibilityLabel("Subtitles")
    }
}
#endif

enum Languages {
    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}
