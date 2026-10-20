# macOS host

The menu bar app that creates virtual displays, captures and encodes them, and streams them to
clients over USB or the network. It also contains the shared Swift protocol and client libraries.

<p align="center"><img src="../docs/images/menu-dark.png" width="360" alt="Menu bar app"></p>

## Requirements

- macOS 14 or later, Apple Silicon recommended (hardware H.264 / HEVC encoder)
- Xcode 16+ (Swift 6) to build
- **Screen Recording** permission (to capture the virtual display)
- **Accessibility** permission (to turn touch and keyboard input into mouse and key events)
- For Android over USB: `adb` from the Android platform tools (`brew install android-platform-tools`)

## Build and run

```bash
cd mac
swift build                         # everything
swift test                          # unit tests (protocol, host, client kit)
scripts/build-app.sh                # build/MacSecondMonitor.app (release, signed)
DMG=1 scripts/build-app.sh          # also build/MacSecondMonitor-<version>.dmg
open build/MacSecondMonitor.app
```

`build-app.sh` signs with the first *Apple Development* or *Developer ID Application* identity in
the keychain (ad-hoc otherwise). Use a stable identity: macOS ties the Screen Recording and
Accessibility grants to the signature, so ad-hoc builds ask again after every rebuild.

If `web/dist` or an Android APK has been built, the script bundles them: the Mac then serves the
web client and can install the Android app on a connected device with one click.

You can also open `Package.swift` in Xcode and run the `MacSecondMonitor` scheme.

## Package layout

| Target | Kind | Contents |
| --- | --- | --- |
| `MSMProtocol` | library (macOS + iOS) | Framing, message types, JSON / binary payloads, input events — the [wire protocol](../docs/PROTOCOL.md) |
| `MSMClientKit` | library (macOS + iOS) | Client connection (HELLO, PING / clock offset, STATS), Annex-B → `CMSampleBuffer`, VideoToolbox decoder |
| `CGVirtualDisplayKit` | Objective-C | Wrapper around the private `CGVirtualDisplay` API, resolved at runtime |
| `MSMHost` | library | Virtual display, ScreenCaptureKit capture, VideoToolbox encoder, TCP / WebSocket / HTTP servers, sessions, pairing, input injection, ADB and usbmux bridges, localization |
| `MacSecondMonitor` | app | SwiftUI menu bar app, settings, onboarding |
| `msm` | CLI | Headless host and test tools (below) |

## `msm` command-line tool

```bash
swift run msm serve --test-pattern --no-pairing    # host a synthetic stream (no permissions needed)
swift run msm serve --usb                          # real host + Android/iOS USB bridges
swift run msm probe 127.0.0.1 --seconds 5 --screenshot /tmp/frame.png
swift run msm display-test                         # create a virtual display, list its modes
swift run msm encode-bench --width 2560 --height 1600
```

`probe` is a complete client: it decodes every frame and prints fps, bitrate, decode time and
capture-to-decode latency.

## How a frame travels

1. `VirtualDisplay` creates a display sized to the client (HiDPI, several "looks like" sizes).
2. `ScreenCapturer` (ScreenCaptureKit) delivers NV12 frames only when the screen changes.
3. `StreamPipeline` keeps at most two unacknowledged frames in flight. While the window is full
   it keeps only the newest capture (latest frame wins), so nothing queues up.
4. `VideoEncoder` encodes with low-latency rate control, no B-frames, keyframes on request.
5. The frame goes out as a `VIDEO` message; the client answers with `ACK`.
6. `InputInjector` turns `INPUT` messages into `CGEvent`s on the virtual display.

`AdaptiveBitrate` lowers the bitrate when the ACK window keeps filling or the RTT grows, and
raises it again once the link is calm.

## Localization

All strings live in [`Sources/MSMHost/Resources/Localizable.xcstrings`](Sources/MSMHost/Resources/Localizable.xcstrings)
(English and Turkish) and are read with `L10n.tr("key")`. `swift build` copies the catalog as-is,
so `L10n` reads it directly during development; `build-app.sh` compiles it into `.lproj` tables.
