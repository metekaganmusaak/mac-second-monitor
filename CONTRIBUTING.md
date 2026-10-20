# Contributing

Thanks for helping! This project spans four codebases that share one wire protocol, so a little
care goes a long way.

## Getting started

| Component | Requirements | Build and test |
| --- | --- | --- |
| macOS host | macOS 14+, Xcode 16+ | `cd mac && swift build && swift test` |
| Android client | JDK 17, Android SDK 36 | `cd android && ./gradlew assembleDebug testDebugUnitTest lintDebug` |
| iOS client | Xcode 16+ | Open `ios/MacSecondMonitorClient.xcodeproj`, or `xcodebuild … build` (see [CLAUDE.md](CLAUDE.md)) |
| Web client | Node.js 22.12+ | `cd web && npm ci && npm test && npm run build` |

You don't need a tablet to work on most things: `swift run msm serve --test-pattern` streams a
synthetic image and `swift run msm probe` is a complete test client. See
[CLAUDE.md](CLAUDE.md#testing-without-hardware) for emulator and simulator workflows.

## Guidelines

- **Protocol changes** start in [docs/PROTOCOL.md](docs/PROTOCOL.md) and land in every client in
  the same pull request, with byte-layout tests on each side.
- **Keep the video path queue-free.** Skipping a frame is fine; buffering one is not.
- **Localize everything.** No user-facing string literals in code. Add English and Turkish for
  every new string ([how](docs/ARCHITECTURE.md#localization)).
- **Match the surrounding code**: naming, file layout and comment density. Comments explain *why*,
  not *what*.
- One logical change per pull request; describe what you tested (devices, OS versions, transport).

## Adding a language

Add the translations to:

- `mac/Sources/MSMHost/Resources/Localizable.xcstrings` (open it in Xcode)
- `android/app/src/main/res/values-<lang>/strings.xml`
- `ios/MacSecondMonitorClient/Resources/Localizable.xcstrings`
- `web/src/i18n/<lang>.json`

…and add the language to the pickers (`L10n.supportedLanguages` on macOS, `language_values` on
Android, the web and iOS language lists).

## Reporting bugs

Include the Mac model and macOS version, the client device and OS, the transport (USB / Wi-Fi /
browser) and, if possible, the statistics overlay values (fps, latency, RTT).
