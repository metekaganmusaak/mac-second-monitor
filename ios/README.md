# iOS / iPadOS client

Native SwiftUI app that turns an iPad or iPhone into an extra display for a Mac running
Mac Second Monitor. The Mac creates a virtual display sized to the device and streams it as H.264
or HEVC; the app decodes it with VideoToolbox (`AVSampleBufferDisplayLayer`) and sends touch,
Apple Pencil, trackpad / mouse and keyboard input back. Protocol: [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

## Using it

**Wi-Fi.** Start Mac Second Monitor on the Mac, keep both devices on the same network and open
the app. Macs found with Bonjour (`_macsecondmon._tcp`) appear under *On this network*. You can
also type an address (`192.168.1.20` or `192.168.1.20:7100`). The first connection asks for the
6-digit code shown on the Mac; after that the device is remembered (the token is kept in the
Keychain).

**USB.** Connect the cable and open Mac Second Monitor on the Mac while the app is open. Over USB
the roles are inverted: the app listens on TCP 7100 (loopback only) and the Mac connects through
`usbmuxd`. USB sessions need no pairing and take over from an active Wi-Fi session; when the
cable is removed the app returns to the Wi-Fi Mac it was using before.

**Input.**

| Gesture | Mac |
| --- | --- |
| Tap | Click |
| Drag (after a short distance) | Click and drag |
| Long press (0.5 s) / two-finger tap | Right click |
| Two-finger drag | Scroll, with momentum after a flick |
| Apple Pencil | Pointer with pressure; hover moves the pointer |
| Trackpad / mouse | Pointer, buttons (right click), scrolling |
| Hardware keyboard | Physical keys (the Mac's input source decides the character) |

The keyboard button in the top-right corner shows the on-screen keyboard (with Esc, Tab and arrow
keys). The menu next to it toggles statistics and disconnects.

Rotating the device reconnects so that the Mac recreates the display in the new
orientation. If the connection drops, the app reconnects with backoff (1, 2, 4, 8 s…), except
when the Mac ended the session or pairing failed.

Settings: statistics overlay, keep the screen on while streaming, and app language (System or
one of the 12 bundled languages; takes effect after restarting the app).

## Building

Requirements: Xcode 16 or later (tested with Xcode 26.4), iOS / iPadOS 16.0 or later.

1. Open `ios/MacSecondMonitorClient.xcodeproj`. The app uses the `MSMProtocol` and
   `MSMClientKit` libraries from the local Swift package in `../mac`.
2. Select the *MacSecondMonitorClient* target → *Signing & Capabilities* and choose your team
   (and, if needed, a unique bundle identifier).
3. Run on a device or simulator.

Command line (simulator, no signing):

```sh
xcodebuild -project ios/MacSecondMonitorClient.xcodeproj -scheme MacSecondMonitorClient \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The project uses Swift 6 language mode. Source files live in folder-synchronized groups, so new
files in `MacSecondMonitorClient/` are picked up without editing the project. User-facing text
lives in `Resources/Localizable.xcstrings` and `InfoPlist.xcstrings`: English (source), Turkish,
German, Spanish, French, Italian, Brazilian Portuguese, Russian, Simplified Chinese, Japanese,
Korean and Arabic (right-to-left).

### Debug launch arguments

Honoured in Debug builds only:

- `-autoConnect HOST[:PORT]` connects on launch, e.g. to `msm serve --test-pattern --port 7400`.
- `-pairingCode 123456` answers the first pairing prompt automatically.
- `-settings.showStats YES` turns on the statistics overlay.

## Limitations

- USB has not been tested on hardware yet (the Mac side is `UsbmuxBridge` in `mac/Sources/MSMHost/USB`).
- In the Simulator USB is disabled: the Simulator shares the Mac's network stack, where the host
  already uses port 7100. Unsigned simulator builds cannot use the Keychain, so pairing tokens
  fall back to `UserDefaults` there.
- Over USB the Mac opens the connection: after a rotation the app ends the session with BYE
  `reconfigure` and waits a few seconds for the Mac to dial back with the new orientation.
- iPadOS keeps some shortcuts for itself (e.g. ⌘-Tab, ⌘-Space, Globe key combinations); they
  do not reach the Mac.
- The stream pauses while the app is in the background; the Mac ends the session after 10 s of
  silence and the app reconnects when it returns.
- Protocol v1 is not encrypted. Use it on networks you trust.
