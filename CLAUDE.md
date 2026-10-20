# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this is

Mac Second Monitor turns tablets, phones and computers into extra displays for a Mac. The macOS
host creates a virtual display, captures it, hardware-encodes H.264/HEVC and streams it over USB or
the network; clients decode it and send touch / keyboard input back.

| Folder | What | Build / test |
| --- | --- | --- |
| `mac/` | Swift package: host app, `msm` CLI, shared `MSMProtocol` + `MSMClientKit` | `swift build`, `swift test`, `scripts/build-app.sh` |
| `android/` | Kotlin client (Android 8+, HarmonyOS 2–4) | `./gradlew assembleDebug testDebugUnitTest lintDebug` |
| `ios/` | SwiftUI client (iOS / iPadOS 16+), uses `../mac` as a local package | `xcodebuild -project ios/MacSecondMonitorClient.xcodeproj -scheme MacSecondMonitorClient -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` |
| `web/` | TypeScript browser client, served by the host | `npm ci && npm test && npm run build` |
| `docs/` | `PROTOCOL.md` (wire contract), `ARCHITECTURE.md`, `ROADMAP.md`; the user guide is the root `README.md` | — |

## Rules that matter

- **The wire protocol is a contract.** Any change goes into `docs/PROTOCOL.md` first, then into
  every implementation: Swift (`mac/Sources/MSMProtocol`), Kotlin (`android/.../protocol`),
  TypeScript (`web/src/protocol.ts`). Keep byte layouts identical and add tests on each side.
- **Latency over completeness.** Never add queues on the video path. The host's ACK window
  (`StreamPipeline.maxFramesInFlight`) and "latest frame wins" must stay intact; clients must ACK
  every frame and render only the newest one.
- **No user-facing string literals.** macOS: `L10n.tr("key")` + `Localizable.xcstrings`;
  Android: `strings.xml` (+ `values-tr`); iOS: String Catalog; web: `src/i18n/*.json`. Every new
  string needs English **and** Turkish.
- Swift is in Swift 6 language mode. Mutable state lives on one serial queue per object
  (`@unchecked Sendable` + queue confinement) or on the main actor for UI. Never `queue.sync`
  onto a session queue from a callback that may already run on it (`HostEngine.notify()` exists
  for this reason).
- Match the surrounding style: small files grouped by concern, comments only for *why*.

## Testing without hardware

- `swift run msm serve --test-pattern --no-pairing` streams synthetic frames (no Screen Recording
  permission, no virtual display). Without `--no-pairing`, loopback clients (probe, simulators,
  browsers) have to pair; add `--state-dir /tmp/msm-state` so test pairings stay out of the real
  trust store. `--allow-origin http://localhost:5173` lets the Vite dev server open the WebSocket.
- `swift run msm probe 127.0.0.1 --seconds 5 --screenshot /tmp/f.png` is a full client that
  decodes and reports fps / latency.
- Android end-to-end: boot an emulator, `adb install` the APK, run `msm serve --test-pattern --usb`
  — the host sets up `adb reverse`, launches the app and streams. `adb shell wm size 2560x1600` +
  `wm density 320` mimics the MatePad 11.
- Use ports other than 7100/7101 for test hosts if the menu bar app is running.

## Gotchas

- `swift build` copies `Localizable.xcstrings` without compiling it; `L10n` falls back to reading
  the JSON catalog. `build-app.sh` compiles it into `.lproj` tables for the app bundle.
- TCC (Screen Recording / Accessibility) grants are tied to the code signature; sign with a stable
  identity or the grants reset on every build.
- `CGVirtualDisplay` is private API, resolved at runtime in `CGVirtualDisplayKit`; macOS removes the
  display when the `MSMVirtualDisplay` object is released.
- VideoToolbox low-latency rate control is H.264-only; hosted CI runners have no hardware encoder,
  so the encode/decode round-trip test is skipped when `CI` is set.
- Android: keep `mipmap-anydpi-v26` (aapt fails to find adaptive icons without the qualifier).

## Commits

Small, focused commits; describe *why*. Don't commit build output (`mac/build`, `.build`,
`android/**/build`, `web/dist`, `node_modules`).
