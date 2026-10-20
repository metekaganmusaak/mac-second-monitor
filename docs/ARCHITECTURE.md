# Architecture

## Overview

```
┌──────────────────────── macOS host ────────────────────────┐        ┌──────────── Client ────────────┐
│                                                             │        │                                │
│  VirtualDisplay ──► Capture ──► Encoder ──► Session ──► Transport ═══╪══► Transport ──► Decoder ──► View │
│  (CGVirtualDisplay) (SCStream)  (VideoToolbox)          (TCP/WS/USB) │        │                     ▲          │
│                                                  ▲          │        │                     │          │
│  InputInjector (CGEvent) ◄──────────────────────┴──────────╪════════╪──── Input capture ──┘          │
└─────────────────────────────────────────────────────────────┘        └────────────────────────────────┘
```

One **session** per connected client. Each session owns its virtual display, capture stream and encoder, so multiple clients can run independently.

## macOS host (`mac/`)

| Module | Responsibility |
|---|---|
| `VirtualDisplay` | Wraps `CGVirtualDisplay` (private API, loaded dynamically). Creates a display matching the client's resolution, refresh rate and HiDPI scale. |
| `Capture` | `SCStream` on the virtual display (Extend) or the main display (Mirror). Delivers `CVPixelBuffer`s in NV12. Only changed frames are delivered. |
| `Encoder` | `VTCompressionSession`, H.264 High (HEVC optional), real-time, no frame reordering, low-latency rate control, keyframes on demand. |
| `Transport` | Protocol-agnostic byte stream: `TCPTransport`, `WebSocketTransport`, `AOATransport` (IOUSBHost), `ADBTransport`, `USBMuxTransport`. |
| `Session` | Handshake, pairing, stats, backpressure (drops frames rather than queueing), adaptive bitrate. |
| `InputInjector` | Maps client input to global coordinates of the virtual display and posts `CGEvent`s. |
| `Discovery` | Bonjour advertising, QR code generation. |
| `UI` | SwiftUI menu bar app, onboarding, settings. |

Requirements: macOS 14+, Screen Recording and Accessibility permissions.

## Wire protocol (draft)

Full spec will live in `docs/PROTOCOL.md` (Phase 0). Summary:

- Length-prefixed binary messages: `type: u8`, `flags: u8`, `length: u32 (BE)`, `payload`.
- Same framing on every transport (TCP, WebSocket binary frames, USB bulk).

| Type | Direction | Purpose |
|---|---|---|
| `HELLO` | C → H | Protocol version, device name, resolution, DPI, refresh rate, supported codecs, locale |
| `PAIR` | both | Pairing code / token exchange |
| `CONFIG` | H → C | Chosen codec, resolution, codec parameter sets (SPS/PPS/VPS) |
| `VIDEO` | H → C | One encoded access unit + capture timestamp |
| `INPUT` | C → H | Pointer / touch / scroll / key / stylus events in normalized coordinates |
| `KEYFRAME_REQ` | C → H | Request an IDR frame (after loss or decoder reset) |
| `PING` / `PONG` | both | RTT measurement |
| `STATS` | C → H | Decode time, dropped frames — feeds adaptive bitrate |
| `BYE` | both | Graceful close |

Design rules:

- **Latency over completeness:** a late frame is dropped, never queued.
- No B-frames; every frame is decodable on arrival.
- Coordinates are normalized (0–1) so input is independent of client scaling.

## Clients

| Client | Decode | Render | USB |
|---|---|---|---|
| Android (`android/`) | `MediaCodec` (low-latency) | `SurfaceView` | AOA, ADB fallback |
| Web (`web/`) | WebCodecs, MSE fallback | `<canvas>` / `<video>` | — |
| iOS (`ios/`) | VideoToolbox | `AVSampleBufferDisplayLayer` | usbmux |

## Localization

Every app ships with English (base) and Turkish. Rules:

1. No user-facing string literals in code; always go through the platform's localization API.
2. String keys are English, dot-separated and stable (e.g. `onboarding.permission.screenRecording.title`).
3. Plurals and formatting use the platform's native mechanisms (String Catalog variations, Android `plurals`, `Intl` on the web).
4. Each app follows the system language by default and offers a manual language override in settings.

| Platform | Mechanism | Location |
|---|---|---|
| macOS / iOS | String Catalog | `Resources/Localizable.xcstrings` |
| Android | Resources | `app/src/main/res/values/strings.xml`, `values-tr/strings.xml` |
| Web | JSON catalogs | `web/src/i18n/en.json`, `tr.json` |

Adding a language = adding translations to these files; no code changes.
