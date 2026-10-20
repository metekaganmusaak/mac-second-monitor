# Android / HarmonyOS client

Native client for Android 8+ phones and tablets, including HUAWEI / Honor devices on HarmonyOS 2–4.
It works over **USB** (lowest latency) and **Wi-Fi**, and does not need Google Play Services.

## Features

- Hardware decoding with `MediaCodec` straight onto a `SurfaceView`, with every low-latency switch
  the device offers (`KEY_LOW_LATENCY`, Qualcomm / HiSilicon / Exynos / Amlogic vendor keys)
- Renders the newest frame only; never builds a queue
- USB through `adb reverse`: the Mac sets up the tunnel and opens the app by itself
- Wi-Fi: Bonjour / NSD discovery, manual IP, one-time pairing code
- Touch: tap = click, drag, long press = right click, two-finger tap = right click,
  two-finger scroll with momentum, three-finger tap = menu; optional one-finger scrolling
- Stylus (M-Pencil) with pressure and hover, Bluetooth mouse and keyboard (Ctrl ↔ ⌘ swap option)
- Soft keyboard for typing on the Mac
- Immersive full screen, highest refresh rate, low-latency Wi-Fi lock, statistics overlay
- English and Turkish, with a per-app language setting

## Using it over USB

1. Enable **Developer options** (tap **Build number** seven times under *About*), then turn on
   **USB debugging** — the [main README](../README.md#android) lists where these are on Samsung,
   Pixel, Xiaomi, HUAWEI / Honor (also enable *Allow ADB debugging in charge only mode*), OnePlus
   and Lenovo devices.
2. Connect the device to the Mac and accept the **Allow USB debugging?** prompt
   (tick *Always allow from this computer*).
3. With Mac Second Monitor running on the Mac, the app opens on the device and the display appears.
   The Mac hands the app a key through adb, so USB connections need no pairing.

The Mac needs `adb` (`brew install android-platform-tools`). If the app isn't installed yet, the
Mac's menu offers **Install App** when it was packaged with the APK.

## Building

Requirements: JDK 17 and the Android SDK (compile SDK 36).

```bash
cd android
./gradlew assembleDebug            # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest        # protocol, HID map, gesture and parsing tests
./gradlew lintDebug
./gradlew assembleRelease          # minified; signed with MSM_ANDROID_KEYSTORE if set
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Release signing reads `MSM_ANDROID_KEYSTORE`, `MSM_ANDROID_KEYSTORE_PASSWORD`,
`MSM_ANDROID_KEY_ALIAS` and `MSM_ANDROID_KEY_PASSWORD`; without them the release APK uses the debug
key.

## Code layout

| Package | Contents |
| --- | --- |
| `protocol` | Wire format ([docs/PROTOCOL.md](../docs/PROTOCOL.md)), input events, Android key code → HID usage table |
| `net` | `HostConnection` (reader / writer threads, PING clock offset, STATS), NSD discovery, USB tunnel probe |
| `video` | `VideoDecoder` (MediaCodec session, decoder selection, low-latency settings) |
| `input` | `GestureMachine` (touch → mouse semantics, unit tested), MotionEvent routing, keyboards |
| `ui` | Connect screen, stream activity, settings, the ADB launch trampoline |
| `data` | Preferences, pairing tokens, recent hosts |

## Limitations

- The orientation is locked while streaming; rotate before connecting.
- USB needs USB debugging. Android Open Accessory (no developer mode) is planned.
- HarmonyOS NEXT cannot run APKs; use the web client there.
