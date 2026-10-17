# OroroTV

A native tvOS client for [ororo.tv](https://ororo.tv), built with SwiftUI.

- Browse shows and movies (popular, new episodes, top rated), with sorting and a genre filter
- Search the whole catalog with the native tvOS keyboard
- Show pages with seasons and episodes, plus "continue watching" and resume
- AVKit player with ororo's external WebVTT subtitles drawn over the video, and a Subtitles menu in the transport bar

It uses ororo.tv's JSON API (`https://ororo.tv/api/v2/`) with HTTP Basic auth (your ororo email and password, stored in the Keychain). Streams are signed HLS URLs played directly by AVPlayer.

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open OroroTV.xcodeproj
```

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

Open a deep link at launch without tvOS's "Open in…?" prompt: `SIMCTL_CHILD_OROROTV_OPEN_URL="ororotv://show/2760" xcrun simctl launch booted dev.olicarter.ororotv`

## App icon

Icon layers and top shelf images are rendered from `tools/ororo-logo.svg`:

```sh
swift tools/render_icons.swift tools/ororo-logo.svg Resources/Assets.xcassets
```
