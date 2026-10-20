# Mac Second Monitor

Turn any tablet, phone or computer into a second display for your Mac — over Wi-Fi or a USB cable.

The primary target is the **HUAWEI MatePad 11**, but the goal is to support Android, HarmonyOS, iOS/iPadOS, Windows, Linux and other Macs as display clients.

> **Status:** Planning. See [docs/ROADMAP.md](docs/ROADMAP.md) for the phased plan and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the technical design.

## How it works

Tablets and phones cannot accept a video signal over USB-C (their ports are display *outputs* only), so plugging in a cable is not enough. Instead:

```
macOS host app                                         Client (tablet / phone / PC)
  1. Creates a virtual display (macOS sees a real monitor)
  2. Captures it (ScreenCaptureKit)
  3. Hardware-encodes it (VideoToolbox, H.264 / HEVC)
  4. Streams it  ───────── Wi-Fi or USB ─────────►      Decodes and shows it full screen
  5. Injects input  ◄────────────────────────────       Touch / stylus / keyboard events
```

The cable is used as a **data link**, the same way Duet Display or Spacedesk work.

**Every phone and tablet client (Android, HarmonyOS, iOS, iPadOS) works over both Wi-Fi and USB cable.**

## Components

| Folder | Platform | Role | Transport |
|---|---|---|---|
| [`mac/`](mac/) | macOS 14+ | **Host** — virtual display, capture, encode, input injection | Wi-Fi, USB |
| [`android/`](android/) | Android 8+, HarmonyOS 2–4 | Native client (priority: MatePad 11) | Wi-Fi, USB (AOA / ADB) |
| [`web/`](web/) | Any modern browser | Zero-install client (Windows, Linux, macOS, iOS, HarmonyOS NEXT) | Wi-Fi / LAN |
| [`ios/`](ios/) | iOS / iPadOS 16+ | Native client | Wi-Fi, USB (usbmux) |

## Platform support

| Client device | Wi-Fi | USB cable | Notes |
|---|---|---|---|
| HUAWEI MatePad 11 (HarmonyOS 2–4) | ✅ | ✅ | Android app (APK) |
| Android phones / tablets | ✅ | ✅ | Android app |
| HarmonyOS NEXT devices | ✅ | ❌ | Web client only (no APK support) |
| iPad / iPhone | ✅ | ✅ | Web client, or native app for USB |
| Windows / Linux / macOS | ✅ | ⚠️ | Web client; wired Ethernet works, USB is not planned |

The host is macOS only. A Windows or Linux host is out of scope for now (see the roadmap).

## Localization

All apps are fully localized. User-facing strings are never hard-coded.

- Initial languages: **English** (base) and **Turkish**
- macOS / iOS: String Catalogs (`.xcstrings`)
- Android: `res/values*/strings.xml`
- Web: JSON message catalogs

Adding a language is a translation-only change; see [docs/ARCHITECTURE.md#localization](docs/ARCHITECTURE.md#localization).

## Requirements (development)

- macOS 14+ with Xcode 16+ (Swift 6)
- Android SDK + JDK 17 (Android client)
- Node.js 20+ (web client)

## License

TBD.
