# OroroTV

A native tvOS, iPadOS and iOS client for [ororo.tv](https://ororo.tv), built with SwiftUI.

Both apps share one codebase (`Sources/`). Where the platforms differ, the iPad uses its own native components: a tab bar that can become a sidebar, toolbar menus for sorting and genres, pop-up/segmented season pickers, pointer hover effects, and Picture in Picture. Sizes for each platform live in `Sources/Platform.swift`.

- Browse shows and movies (popular, new episodes, top rated), with sorting and a genre filter
- AirPlay to an Apple TV from iPhone or iPad, subtitles included: while AirPlay is the route, `Sources/PlaylistServer.swift` serves the subtitled playlists over HTTP on the phone's Wi-Fi address (the Apple TV can't use the private-scheme stream), and the player swaps to that copy at the same position
- Search the whole catalog (native tvOS keyboard; the system search tab on iPad)
- Show pages with seasons and episodes, plus "continue watching" and resume
- AVKit player with ororo's external WebVTT subtitles. On tvOS they're drawn over the video with a Subtitles menu in the transport bar. On iPad the app adds them to the HLS stream as real subtitle renditions (`Sources/SubtitledStream.swift`), so AVKit's own full-screen player lists them in its subtitles menu and draws them, Picture in Picture included

It uses ororo.tv's JSON API (`https://ororo.tv/api/v2/`) with HTTP Basic auth (your ororo email and password, stored in the Keychain). Streams are signed HLS URLs played directly by AVPlayer.

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open OroroTV.xcodeproj
```

Schemes: `OroroTV` (Apple TV, tvOS 17+) and `OroroiOS` (iPhone and iPad, iOS 18+). They share the bundle ID `dev.olicarter.ororotv`, so the commands below work for either simulator.

Set your signing team in `project.yml` (`DEVELOPMENT_TEAM`) before regenerating, or Xcode will lose it.

## Deep links

`ororotv://show/<id>`, `ororotv://movie/<id>`, `ororotv://play/episode/<id>`, `ororotv://play/movie/<id>`, `ororotv://search?q=<text>`, `ororotv://tab/<home|shows|movies|search|settings>`

## Simulator helpers (debug builds only)

Sign in from a terminal instead of the on-screen keyboard:

```sh
read "E?ororo email: " && read -s "P?ororo password: " && echo && \
  SIMCTL_CHILD_OROROTV_EMAIL="$E" SIMCTL_CHILD_OROROTV_PASSWORD="$P" \
  xcrun simctl launch --terminate-running-process booted dev.olicarter.ororotv; unset E P
```

Open a deep link at launch without the "Open in…?" prompt: `SIMCTL_CHILD_OROROTV_OPEN_URL="ororotv://show/2760" xcrun simctl launch booted dev.olicarter.ororotv`

## App icon

The tvOS icon layers and top shelf images, and the iPad icon, are rendered from `tools/ororo-logo.svg`:

```sh
swift tools/render_icons.swift tools/ororo-logo.svg Resources/Assets.xcassets
```

## Sharing with friends (ad hoc)

Friends install the iOS app from https://4n.studio/ororo/. The script that registers their devices, builds the ad hoc copy and publishes the page lives in `~/Developer/4n-studio` (shared with Seek):

```sh
~/Developer/4n-studio/adhoc.py add "Their name" <udid>
~/Developer/4n-studio/adhoc.py build ororo
~/Developer/4n-studio/adhoc.py deploy
```

A build only installs on devices registered when it was made, so rebuild and redeploy after adding someone.
