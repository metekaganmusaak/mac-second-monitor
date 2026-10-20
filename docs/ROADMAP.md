# Roadmap

Each phase ends with a usable result and a clear exit criterion. Phases are ordered by the priority device (HUAWEI MatePad 11) first, then broad compatibility.

## Core requirement

**Every phone and tablet client (Android, HarmonyOS 2–4, iOS, iPadOS) must work as a second display over both Wi-Fi and a USB cable.** USB is a first-class transport, not an add-on:

- The host's transport layer is designed for USB from Phase 1, so Wi-Fi and USB share the same session and stream code.
- A platform is considered done only when both transports meet the latency targets below.
- The web client is the only Wi-Fi-only client (browsers cannot access USB data links); it exists for desktops and devices without a native app.

**Performance targets** (apply from Phase 1 onward, measured glass-to-glass):

| Link | Frame rate | Latency target |
|---|---|---|
| 5 GHz Wi-Fi | 60 fps | < 60 ms |
| USB | 60 fps | < 35 ms |

Reference resolution: 2560×1600 (MatePad 11 native).

---

## Phase 0 — Foundations & technical spikes

Validate the risky parts before building on them.

- [ ] Repository layout, `.gitignore`, coding conventions, CI skeleton (GitHub Actions)
- [ ] Spike: create a `CGVirtualDisplay` on macOS 26 / Apple Silicon (resolution, refresh rate, HiDPI)
- [ ] Spike: capture the virtual display with ScreenCaptureKit at 60 fps
- [ ] Spike: VideoToolbox H.264 low-latency encode (no B-frames, low-latency rate control), measure encode time
- [ ] Spike: web decode path — WebCodecs (needs a secure context) vs. Media Source Extensions over plain HTTP
- [ ] Draft wire protocol spec (`docs/PROTOCOL.md`)

**Exit:** a command-line prototype streams the virtual display to a local test viewer at 60 fps.

## Phase 1 — macOS host MVP

- [ ] Menu bar app (SwiftUI `MenuBarExtra`), launch at login
- [ ] Virtual display lifecycle: create per connected client, sized to the client's resolution and DPI
- [ ] Display modes: **Extend** (virtual display) and **Mirror** (capture the main display)
- [ ] Capture → encode pipeline with frame dropping when the client falls behind
- [ ] Transport abstraction (byte stream interface) shared by Wi-Fi and USB transports
- [ ] Network server: TCP (native clients) + WebSocket (web client)
- [ ] Bonjour advertising (`_macsecondmon._tcp`) and QR code with connection URL
- [ ] Pairing: 6-digit code / one-time token, remembered trusted devices
- [ ] Input injection via `CGEvent` (Accessibility permission): pointer, click, drag, scroll, keyboard
- [ ] Permission onboarding (Screen Recording, Accessibility)
- [ ] Localization: String Catalog, English + Turkish

**Exit:** host runs from the menu bar, advertises itself and serves a stream to a test client.

## Phase 2 — Android / HarmonyOS client over Wi-Fi (MatePad 11)

- [ ] Kotlin app, min SDK 26, no Google Play Services dependency (Huawei devices)
- [ ] Discovery (NSD/mDNS) + manual IP entry + QR scan
- [ ] Hardware decode with `MediaCodec` in low-latency mode onto a `SurfaceView`
- [ ] Immersive full screen, keep screen on, landscape/portrait handling
- [ ] Touch mapping: tap → click, long-press → right click, two-finger → scroll, drag; stylus (M-Pencil) as pointer
- [ ] Reports native resolution / DPI so the host sizes the virtual display correctly
- [ ] Reconnect on network change, keyframe request on decode error
- [ ] Latency / FPS overlay (debug)
- [ ] Localization: `strings.xml`, English + Turkish
- [ ] Signed release APK on GitHub Releases

**Exit:** MatePad 11 works as an extended display over 5 GHz Wi-Fi at 60 fps within the latency target.

## Phase 3 — USB connection for Android

- [ ] **AOA (Android Open Accessory)**: host talks to the device over USB via `IOUSBHost`; no developer mode needed
- [ ] Android side: `UsbAccessory` handling, auto-launch on cable connect, permission prompt
- [ ] Fallback: **ADB** port forwarding (`adb reverse`) for devices without AOA
- [ ] Transport abstraction on both sides so the stream code is identical for Wi-Fi and USB
- [ ] Automatic transport selection (prefer USB when present)

**Exit:** plugging the MatePad into the Mac connects it as a display with one tap, within the USB latency target.

## Phase 4 — iOS / iPadOS native client (Wi-Fi + USB)

- [ ] SwiftUI app, VideoToolbox decode to `AVSampleBufferDisplayLayer`
- [ ] Wi-Fi: Bonjour discovery + TCP transport
- [ ] USB via usbmux: the app listens on a local port, the host connects through the device's USB multiplexer (no network needed)
- [ ] Automatic transport selection (prefer USB when the cable is connected)
- [ ] Touch, Apple Pencil (pressure/hover where available) and hardware keyboard
- [ ] Localization: String Catalog, English + Turkish

**Exit:** iPad and iPhone work as an extended display over both Wi-Fi and USB within the latency targets.

## Phase 5 — Web client (universal, Wi-Fi / LAN)

- [ ] Static client served by the host app itself (no install on the client)
- [ ] Decode path chosen in Phase 0: WebCodecs (HTTPS / self-signed) with MSE / ManagedMediaSource fallback
- [ ] Full screen, wake lock, pointer + touch + keyboard input
- [ ] "Add to Home Screen" (PWA) for iOS Safari full screen
- [ ] Localization: JSON catalogs, English + Turkish, browser-language detection
- [ ] Tested on: Chrome/Edge (Windows, Linux), Safari (macOS, iPadOS, iOS), Huawei Browser, Firefox

**Exit:** any device with a modern browser on the same network can be used as a display.

## Phase 6 — Polish & performance

- [ ] Adaptive bitrate / resolution based on measured RTT and frame loss
- [ ] HEVC when the client supports it; 120 fps mode for 120 Hz clients
- [ ] Multiple clients at once (one virtual display each)
- [ ] Display arrangement memory per device
- [ ] Settings UI on all apps (quality, frame rate, input mapping, language override)
- [ ] Packaging: notarized DMG (or signed build), APK, web bundle; release automation
- [ ] Additional languages (contributions welcome)

## Out of scope (for now)

- **Windows host** — requires a signed Indirect Display (IddCx) driver
- **Linux host** — possible (EVDI / virtual outputs), not planned yet
- **HarmonyOS NEXT native app** (ArkTS) — Wi-Fi is covered by the web client; a native app would be needed for USB on NEXT devices
- **App Store distribution** of the Mac app — `CGVirtualDisplay` is a private API

## Open questions

- Exact HarmonyOS version on the target MatePad 11 (NEXT would move the web client ahead of Phase 2)
- License
