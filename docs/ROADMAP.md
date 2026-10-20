# Roadmap

Each phase ends with a usable result and a clear exit criterion. Phases start with the first target
platform (Android tablets, with the HUAWEI MatePad 11 as the reference device), then broaden
compatibility.

**Legend:** ✅ done and verified · 🟡 implemented, not yet verified on real hardware · ⬜ not done

## Core requirement

**Every phone and tablet client (Android, HarmonyOS 2–4, iOS, iPadOS) must work as a second display
over both Wi-Fi and a USB cable.** USB is a first-class transport, not an add-on:

- The host's transport layer treats USB tunnels and Wi-Fi the same way: one session and stream
  implementation behind a `MessageChannel`.
- A platform is considered done only when both transports meet the latency targets below.
- The web client is the only Wi-Fi-only client (browsers cannot use USB data links); it exists for
  desktops and devices without a native app.

**Performance targets** (measured glass-to-glass):

| Link | Frame rate | Latency target |
| --- | --- | --- |
| 5 GHz Wi-Fi | 60 fps | < 60 ms |
| USB | 60 fps | < 35 ms |

Reference resolution: 2560×1600 (a typical 11-inch tablet).

**Measured so far** (M4 Pro host): hardware H.264 encode of 2560×1600 ≈ 9 ms; capture → decoded on
the same Mac ≈ 23 ms median with a real virtual display; Android emulator over the USB tunnel at
2560×1600 ≈ 15–22 ms capture → rendered (test pattern). Physical-tablet numbers are still to come.

---

## Phase 0 — Foundations & technical spikes ✅

- ✅ Repository layout, `.gitignore`, conventions ([CLAUDE.md](../CLAUDE.md), [CONTRIBUTING.md](../CONTRIBUTING.md)), CI ([.github/workflows](../.github/workflows))
- ✅ Spike: `CGVirtualDisplay` on macOS 26 / Apple Silicon (resolution, refresh rate, HiDPI) — `msm display-test`
- ✅ Spike: ScreenCaptureKit capture of the virtual display at 60 fps
- ✅ Spike: VideoToolbox low-latency H.264 (no B-frames, low-latency rate control) — `msm encode-bench`
- ✅ Spike: web decode path — WebCodecs in secure contexts, MSE + fragmented MP4 on plain HTTP
- ✅ Wire protocol spec ([PROTOCOL.md](PROTOCOL.md))

**Exit ✅:** `msm serve` streams the virtual display to `msm probe` (a decoding test client) at 60 fps.

## Phase 1 — macOS host MVP ✅

- ✅ Menu bar app (SwiftUI `MenuBarExtra`), launch at login
- ✅ Virtual display per connected client, sized to its resolution and DPI, arrangement remembered per device
- ✅ Display modes: **Extend** (virtual display) and **Mirror** (main display, aspect-fit)
- ✅ Capture → encode pipeline with frame skipping when the client falls behind (ACK window, latest frame wins)
- ✅ Transport abstraction shared by Wi-Fi and USB
- ✅ Network server: TCP (native clients) + HTTP / WebSocket (web client) on one port
- ✅ Bonjour advertising (`_macsecondmon._tcp`) and a QR code for the browser client
- ✅ Pairing: 6-digit code, three attempts, remembered trusted devices (token hashes only)
- 🟡 Input injection via `CGEvent`: pointer, click counting, drag, trackpad-style scroll, keys, text (mapping unit-tested; posting needs the Accessibility grant, not exercised in automated tests)
- ✅ Permission onboarding (Screen Recording, Accessibility)
- ✅ Localization: String Catalog, English + Turkish

**Exit ✅:** the host runs from the menu bar, advertises itself and serves streams to test clients.

## Phase 2 — Android / HarmonyOS client over Wi-Fi 🟡

- ✅ Kotlin app, min SDK 26, no Google Play Services dependency
- ✅ Discovery (NSD / mDNS) + manual IP entry; ⬜ in-app QR scanning (the menu's QR code opens the web client instead)
- ✅ Hardware decode with `MediaCodec` in low-latency mode (plus Qualcomm / HiSilicon / Exynos / Amlogic vendor keys) onto a `SurfaceView`
- ✅ Immersive full screen, keep screen on, highest refresh rate, orientation locked while streaming
- ✅ Touch mapping: tap → click, long-press → right click, two-finger tap → right click, two-finger scroll with momentum, drag; stylus (M-Pencil) with pressure and hover; mouse; hardware and soft keyboard
- ✅ Reports native resolution / DPI / refresh rate so the host sizes the virtual display
- ✅ Reconnect on network loss (incl. a silence timeout), keyframe request on decoder errors
- ✅ Statistics overlay (fps, latency, RTT, bitrate, decoder)
- ✅ Localization: `strings.xml`, English + Turkish, per-app language setting
- 🟡 Signed release APK: `assembleRelease` + release workflow (needs the signing secrets)

**Exit 🟡:** verified end-to-end in the Android emulator; to be confirmed on a physical tablet over 5 GHz Wi-Fi.

## Phase 3 — USB connection for Android 🟡

- ✅ **ADB** port forwarding (`adb reverse`), set up automatically by the host for every authorized device
- ✅ Auto-launch on cable connect (`am start` of a trampoline activity) and one-click install of the bundled APK
- ✅ Same stream code for Wi-Fi and USB on both sides; the app prefers USB whenever the tunnel is up
- ⬜ **AOA (Android Open Accessory)** via `IOUSBHost` — would remove the need for USB debugging; needs real hardware to develop and test

**Exit 🟡:** in the emulator, plugging in (= `adb` attach) connects as a display without any tap,
at ~15–22 ms; to be confirmed on a physical tablet.

## Phase 4 — iOS / iPadOS native client (Wi-Fi + USB) 🟡

- ✅ SwiftUI app, `AVSampleBufferDisplayLayer` rendering, shares `MSMProtocol` / `MSMClientKit` with the host
- ✅ Wi-Fi: Bonjour discovery + TCP transport, pairing
- 🟡 USB via usbmux: the app listens on port 7100, the host's `UsbmuxBridge` connects through `usbmuxd` (protocol verified against the real daemon; no device tested)
- ✅ Automatic transport selection (a USB connection takes over)
- 🟡 Touch, Apple Pencil (pressure / hover), trackpad / mouse and hardware keyboard
- ✅ Localization: String Catalog, English + Turkish

**Exit 🟡:** verified in the iPad simulator over TCP; USB and Pencil need a real device.

## Phase 5 — Web client (universal, Wi-Fi / LAN) 🟡

- ✅ Static client served by the host app itself (no install on the client)
- ✅ WebCodecs on secure contexts (localhost / HTTPS), MSE / ManagedMediaSource fallback on plain HTTP
- ✅ Full screen, wake lock, pointer + touch + pen + keyboard + soft keyboard input
- ✅ "Add to Home Screen" (PWA manifest, Apple meta tags)
- ✅ Localization: JSON catalogs, English + Turkish, browser-language detection, `?lang=` override
- 🟡 Tested on Chrome (macOS). Safari (macOS / iPadOS / iOS), Edge, Firefox and Huawei Browser still to test
- ⬜ HTTPS with a local certificate, so LAN browsers get WebCodecs (lower latency than MSE)

**Exit 🟡:** any modern browser on the network can be used as a display; verified in Chrome.

## Phase 6 — Polish & performance 🟡

- ✅ Adaptive bitrate from ACK-window stalls and RTT growth (`AdaptiveBitrate`)
- ✅ HEVC when the client supports it (opt-in), 30 / 60 / 120 fps setting (capped at the client's panel)
- ✅ Multiple clients at once (one virtual display each)
- ✅ Display arrangement memory per device (stable display serial per device ID)
- ✅ Settings on all apps (quality, frame rate, codec, input mapping, language override)
- ✅ Packaging: `build-app.sh` (signed `.app`, DMG), release APK, web bundle; tag-triggered release workflow
- ⬜ Notarization (needs a Developer ID certificate)
- ✅ 12 languages in every app (English, Turkish, German, Spanish, French, Italian, Brazilian Portuguese, Russian, Simplified Chinese, Japanese, Korean, Arabic) — more welcome

## Out of scope (for now)

- **Windows host** — requires a signed Indirect Display (IddCx) driver
- **Linux host** — possible (EVDI / virtual outputs), not planned yet
- **HarmonyOS NEXT native app** (ArkTS) — Wi-Fi is covered by the web client; a native app would be needed for USB on NEXT devices
- **App Store distribution** of the Mac app — `CGVirtualDisplay` is a private API

## Open questions

- Exact HarmonyOS version on the target MatePad 11 (NEXT can't run the APK; the web client covers it over Wi-Fi)
- License
