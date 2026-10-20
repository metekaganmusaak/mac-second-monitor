# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- When the Mac app quits, devices no longer retry in a loop: the Mac says goodbye before it exits,
  and the Android app shows "Mac Second Monitor was closed on the Mac" and reconnects by itself as
  soon as the app is running again (also after a crash or a dropped link, after three quick
  retries). iOS and the browser client stop instead of retrying.
- The Mac app is now called **Mac Second Monitor** everywhere (app bundle, process name, privacy
  settings); the browser client's home-screen name too.

## [0.1.0] — 2026-10-20

First public preview. Every phase of the [roadmap](docs/ROADMAP.md) has a working
implementation; it has been verified on macOS 26, in the Android emulator, the iOS simulator and
Chrome, but **not yet on physical tablets** — feedback is very welcome.

**Downloads:** `MacSecondMonitor-0.1.0.dmg` (Mac app; includes the browser client and the Android
APK for one-click install) and `MacSecondMonitor-0.1.0.apk` (Android 8+ / HarmonyOS 2–4).

### Added

**macOS host (menu bar app)**
- Virtual display per connected device (`CGVirtualDisplay`): native resolution, HiDPI, 60 / 120 Hz,
  several "looks like" sizes, arrangement remembered per device; **Extend** and **Mirror** modes.
- ScreenCaptureKit capture and VideoToolbox hardware encoding (H.264 with low-latency rate
  control, optional HEVC), no B-frames, keyframes on request.
- Queue-free flow control: at most two unacknowledged frames in flight, latest frame wins;
  adaptive bitrate when the link backs up.
- Connections over USB (Android through `adb reverse`, set up automatically; iPhone / iPad
  through usbmux), Wi-Fi (Bonjour discovery) and a built-in web server for browsers.
- Pairing for network devices with a 6-digit code (notification + menu), trusted-device list.
- Touch, pen, scroll (trackpad-style phases and momentum), keyboard and text input via `CGEvent`.
- Onboarding for Screen Recording and Accessibility, settings (quality, frame rate, codec, USB,
  language, launch at login), QR code for the browser client, one-click Android app install.
- `msm` command-line tool: headless host, decoding test client, virtual display test, encoder
  benchmark.

**Android / HarmonyOS app**
- MediaCodec low-latency decoding (plus vendor switches for Qualcomm, HiSilicon, Exynos and
  Amlogic), newest-frame rendering, highest refresh rate, low-latency Wi-Fi lock.
- Plug-and-play USB: the Mac opens the app; connections prove themselves with a key passed over adb.
- Wi-Fi discovery, manual address, pairing, recent hosts, automatic reconnect.
- Gestures (tap, drag, long press, two-finger tap and scroll with momentum, three-finger menu),
  stylus with pressure and hover, mouse, hardware keyboard (Ctrl ↔ ⌘ option), soft keyboard.
- Statistics overlay, settings, per-app language.

**iOS / iPadOS app**
- `AVSampleBufferDisplayLayer` rendering (H.264 / HEVC), Bonjour and manual connections, pairing.
- USB via usbmux (the app listens, the Mac dials), automatic switch between USB and Wi-Fi,
  reconnect after rotation.
- Touch, Apple Pencil (pressure, hover), trackpad / mouse, hardware and on-screen keyboard.

**Web client**
- Zero-install client served by the Mac: WebCodecs on secure contexts, MSE / fragmented-MP4
  fallback on plain HTTP; pointer, touch, pen, keyboard and soft keyboard; PWA manifest.

**Everywhere**
- 12 languages: English, Turkish, German, Spanish, French, Italian, Brazilian Portuguese, Russian,
  Simplified Chinese, Japanese, Korean and Arabic (right-to-left).
- Pairing codes can be typed with any digits the keyboard produces (Arabic-Indic, full-width).
- Wire protocol v1 ([PROTOCOL.md](docs/PROTOCOL.md)), CI for all four apps.

### Security
- Network devices must pair; one pairing at a time and growing lockouts after wrong codes.
- The WebSocket endpoint checks `Origin`, so other websites can't connect to the Mac.
- Only a hash of each pairing token is stored on the Mac.

### Known limitations
- The stream is not encrypted yet (use trusted networks).
- Android over USB needs USB debugging; Android Open Accessory (no developer mode) is planned.
- The Mac app is not notarized: on first launch use right-click → **Open** (or *System Settings →
  Privacy & Security → Open Anyway*).
- The Android APK in this release is signed with a development key; a future release signed with
  a permanent key will require uninstalling this one first.
- The iOS app is not on the App Store; build it with Xcode.
- Rotating an Android device while streaming isn't supported (the orientation is locked).

[Unreleased]: https://github.com/metekaganmusaak/mac-second-monitor/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/metekaganmusaak/mac-second-monitor/releases/tag/v0.1.0
