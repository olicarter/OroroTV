import SwiftUI

/// Sizes and spacing that differ between the 10-foot tvOS UI and iPad.
enum Metrics {
    #if os(tvOS)
    static let poster = CGSize(width: 240, height: 360)
    static let gridColumns = Array(repeating: GridItem(.fixed(240), spacing: 48), count: 6)
    static let gridSpacing: CGFloat = 60
    static let shelfSpacing: CGFloat = 40
    /// Room above and below a shelf for the focused card's lift.
    static let shelfInset: CGFloat = 30
    static let margin: CGFloat = 60
    static let detailMargin: CGFloat = 80
    static let detailSpacing: CGFloat = 60
    static let buttonSpacing: CGFloat = 30
    static let episodeNumberWidth: CGFloat = 70
    static let episodePadding: CGFloat = 24
    static let episodeProgressWidth: CGFloat = 300
    static let subtitleSize: CGFloat = 46
    #else
    static let poster = CGSize(width: 150, height: 225)
    static let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: 20)]
    static let gridSpacing: CGFloat = 28
    static let shelfSpacing: CGFloat = 16
    static let shelfInset: CGFloat = 8
    static let margin: CGFloat = 24
    static let detailMargin: CGFloat = 32
    static let detailSpacing: CGFloat = 24
    static let buttonSpacing: CGFloat = 12
    static let episodeNumberWidth: CGFloat = 36
    static let episodePadding: CGFloat = 14
    static let episodeProgressWidth: CGFloat = 180
    static let subtitleSize: CGFloat = 26
    #endif
}

extension View {
    /// tvOS's focus-lift card; on iPad a rounded tile with the pointer lift effect.
    @ViewBuilder func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        buttonStyle(.plain)
            .background(.fill.quaternary, in: shape)
            .clipShape(shape)
            .contentShape(.hoverEffect, shape)
            .contentShape(.contextMenuPreview, shape)
            .hoverEffect(.lift)
        #endif
    }

    /// Main call to action: tvOS's default focusable button, a filled button on iPad.
    @ViewBuilder func primaryButtonStyle() -> some View {
        #if os(tvOS)
        self
        #else
        buttonStyle(.borderedProminent).controlSize(.large)
        #endif
    }

    @ViewBuilder func secondaryButtonStyle() -> some View {
        #if os(tvOS)
        self
        #else
        buttonStyle(.bordered).controlSize(.large)
        #endif
    }

    /// Groups focus movement on tvOS; touch needs nothing.
    @ViewBuilder func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}
