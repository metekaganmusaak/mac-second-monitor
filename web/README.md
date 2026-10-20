# Web client

Zero-install browser client for Mac Second Monitor. Open it on a tablet, phone or PC on the same
network and that device becomes a display for your Mac: the page decodes the H.264 stream, shows it
full screen and sends touch, mouse, pen and keyboard input back.

TypeScript + Vite, no runtime dependencies. It speaks wire protocol v1 ([docs/PROTOCOL.md](../docs/PROTOCOL.md)).

## How it is served

The Mac app serves the built bundle (`web/dist/`) as static files on HTTP port **7101** and upgrades
`GET /ws` on the same port to the WebSocket session. Asset paths are relative, so the bundle works
from any directory. On a client, open `http://<mac-ip>:7101/`.

| Query parameter | Effect |
| --- | --- |
| `?host=IP:PORT` | Connect to another host than the page's origin (e.g. while running `vite dev`) |
| `?lang=de`, `?lang=pt-BR`, … | Override the browser language (remembered; `?lang=auto` clears it) |
| `?decoder=mse` / `?decoder=webcodecs` | Force a decode path (testing) |
| `?stats=1` | Show the statistics overlay |

"Add to Home Screen" (iOS / iPadOS Safari, Android) installs it as a full-screen web app.

## Development

Node.js 22.12+.

```sh
npm install
npm run dev          # http://localhost:5173/?host=127.0.0.1:7101 — talks to a running host
                     # started with: msm serve --allow-origin http://localhost:5173
npm run build        # type-check + bundle to dist/
npm test             # vitest unit tests
```

A host without Screen Recording permission, for testing:

```sh
msm serve --test-pattern --no-pairing --web-root web/dist
```

Code map: `src/protocol.ts` (framing, messages, INPUT encoding), `src/connection.ts` (WebSocket session,
PING / clock offset, STATS), `src/decoder/` (WebCodecs and MSE pipelines), `src/video/` (Annex-B,
SPS parsing, fMP4 muxer), `src/input/` (pointer, touch gestures, keyboard, HID table),
`src/ui/` (screens, toolbar, overlays), `src/i18n/*.json` (strings).

## Decoding: secure context vs. plain HTTP

Browsers only expose **WebCodecs** in a secure context (HTTPS or `localhost`). There the client decodes
each frame as it arrives and draws it to a canvas: the lowest latency.

On plain `http://192.168.x.x:7101` the client falls back to **Media Source Extensions**
(`ManagedMediaSource` on iPhone): each frame is wrapped in a fragmented MP4 fragment and the
playhead is kept a few frames behind the newest one. In our tests (Chrome on macOS, test pattern) the
capture-to-display estimate was about 5–20 ms with WebCodecs and 40–60 ms with MSE. The page shows a
notice in this mode.

Until the host serves HTTPS, Chromium browsers can be told to treat the Mac's address as secure:
`chrome://flags/#unsafely-treat-insecure-origin-as-secure` → `http://<mac-ip>:7101`.

Screen Wake Lock also needs a secure context; over plain HTTP the device may dim while streaming.

## Browser support

| Browser | HTTPS / localhost | Plain HTTP (LAN) | Tested |
| --- | --- | --- | --- |
| Chrome / Edge (Windows, macOS, Linux, ChromeOS) | WebCodecs | MSE | Chrome 155 on macOS (headless), both paths |
| Chrome (Android), Samsung Internet, Huawei Browser | WebCodecs | MSE | not yet |
| Safari 16.4+ (macOS, iPadOS) | WebCodecs | MSE | not yet |
| Safari on iPhone | WebCodecs (16.4+) | ManagedMediaSource (17.1+) | not yet |
| Firefox 130+ (desktop) | WebCodecs | MSE | not yet |
| Firefox (Android) | WebCodecs if the version has it, otherwise MSE | MSE | not yet |

## Input

| On the client | Sent to the Mac |
| --- | --- |
| Mouse | Pointer moves, left / right / middle buttons, wheel (pixel or line deltas) |
| Tap | Click |
| Drag (after 8 px) | Click-and-drag |
| Long press (500 ms) / two-finger tap | Right click |
| Two-finger drag | Trackpad-style scrolling, with momentum after a fling |
| Pen | Stylus pointer with pressure; hover moves the cursor |
| Hardware keyboard | Physical keys as USB HID usages (the Mac's keyboard layout applies) |
| Soft keyboard (toolbar button) | Typed text, plus Backspace / Return |

## Localization

Strings live in `src/i18n/<tag>.json` (dot-separated English keys): `en`, `tr`, `de`, `es`, `fr`, `it`,
`pt-BR`, `ru`, `zh-CN`, `ja`, `ko`, `ar`. Other regions fall back to the catalog of their base language
(`de-AT` → `de`, `pt-PT` → `pt-BR`, `zh-TW` → `zh-CN`). Plural keys (`key.one`, `key.few`, …) need exactly the
categories `Intl.PluralRules` reports for the language. Arabic sets `dir="rtl"`: the UI chrome mirrors, the
video stage stays left-to-right. Adding a language means adding a catalog and registering it in `src/i18n.ts`;
`tests/i18n.test.ts` checks keys, placeholders and plural forms of every catalog.
