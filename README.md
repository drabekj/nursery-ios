# Chůvička (Nursery) — a local-only baby monitor for iOS and Android

It shows the camera in the nursery and plays its sound in real time. It continues on the lock screen and in
picture in picture. It uses no cloud service. Three sources: a camera through a go2rtc server, an IP camera
read directly (RTSP), or an old phone at the baby (iOS or Android) that sends to the parents' phones.
The iOS app has no third-party code; the Android app uses AndroidX, CameraX and zxing (the QR code).

The state of the app for other users, and the roadmap: `docs/READINESS.md`.

The diagram below is the developer's own setup. Its addresses and stream names are the app's initial
values, kept in one place (`Nursery/App/HomeDefaults.swift`, `android/.../HomeDefaults.kt`), so a public
build empties them and changes nothing else.

```
 iPhone app                                   Raspberry Pi 192.168.0.136
 ┌─────────────────────────────┐   RTSP/TCP    ┌───────────────────────────────┐   RTSP    ┌──────────┐
 │ RTSPClient (Network.fw)     │──── 8554 ────►│ go2rtc  nursery / nursery_sd  │◄──────────│ Tapo TC72│
 │  ├ H.264 → AVSampleBuffer…  │               │         (the only camera      │   one     └──────────┘
 │  │   DisplayLayer ─► PiP    │               │          client)              │  client
 │  └ G.711 → AVAudioEngine    │   HTTP 1984   │ /nursery/config.js (ids)      │
 │ Webhooks (pan/tilt, power) ─┼──── 8123 ────►│ Home Assistant → nursery_ptz  │
 └─────────────────────────────┘               └───────────────────────────────┘
```

## Why a native app

The web page could not do three things at once on iOS:

| Need | Web page | This app |
|---|---|---|
| Sound in sync with the picture | No. The HLS/AAC audio came several seconds late. | Yes. The sound and the picture come in the same RTSP session. The audio queue holds 120 to 400 ms. |
| Sound with the screen locked | Only with the delayed AAC stream | Yes. `UIBackgroundModes: audio`, and `AVAudioSession` `.playback` |
| Picture in picture | No. WebKit cannot put a WebRTC stream in the small window. | Yes. `AVPictureInPictureController` with the sample-buffer layer. It opens automatically when you swipe home. |

## Features

**The screen.** The picture is the hero, with concentric corners. Below it you see the room: its state in
large words ("Quiet", "Some sound", "Loud"), the time of the last sound, and a waveform of the last
6 seconds. You can *see* a cry, also with the phone muted. The four actions sit in a Liquid Glass bar at
the thumb: **Sound · Move · Photo · Night**. One status badge (Live / Reconnecting / Offline) sits in the
navigation bar. The background glows softly with the loudness of the room.

- **Three sound modes.** Tap Sound to turn it on or off. Touch and hold it for the other options.
  - **Live:** you hear the room with a delay of about 0.1–0.4 s, in sync with the picture.
  - **Silent:** you hear nothing, but Nursery keeps listening and sends a notification when the baby makes a sound.
  - **Off.**
  - **Loudness:** Normal, Loud (+12 dB), or Max (+20 dB), with a soft limiter.
- **Activity.** Sound events (a sound for 1 s above the sensitivity), a Swift Charts chart of the last hour,
  and the list of today. It answers "did she cry while I was in the shower?" Sensitivity: only crying,
  crying and fussing, or every sound.
- **Move** puts arrows on the picture itself, so you watch while you aim. Tap for one step, or hold to keep turning.
  The pinch zoom (1–4×, double tap) changes only your screen.
- **Photo** takes one full frame of the main stream from go2rtc and opens the share sheet.
- **Night** makes the screen black at minimum brightness, with a dim clock and waveform. The waveform
  brightens while a sound lasts.
- **Picture in picture** opens by itself when you swipe home. **Full screen** comes with a button, or when you turn the phone.
- **Lock Screen and Dynamic Island** (a Live Activity): Listening or Silent, with the loudness bars, or "No sound".
  If the app stops, the activity turns stale after 30 s, so a dead monitor never looks alive.
- **Alerts:** when the sound stops for 20 s, and on sound (in Silent mode, or when you turn it on in Live mode).
  Nursery offers alerts after the first good connection, not at launch.
- **It recovers by itself:** a reconnect after 1, 2, 4, then each 8 s, and at once when the Wi-Fi returns.
  "Offline" shows Try Again and a link to the Settings app (for the local network permission).
- **Battery:** in the background with no picture in picture, Nursery asks go2rtc for the sound only.
- **Siri and Shortcuts:** "Listen to the nursery with Nursery". It also works on the Action button.
- **iPad:** the picture on the left, and the room and the controls on the right.
- **Accessibility:** VoiceOver labels and hints, Reduce Motion, and the system text styles.

## Demo mode and screenshots

`-demo YES` shows a synthetic night-vision frame and a fake sound (a short "cry" each 12 s), with no server.
`-demoScreen aim|activity|night|night-controls|settings|settings-advanced|remote|help|alerts|paused|muted|volume|wizard-…` opens that screen at launch. CI runs the demo in the iOS
Simulator, and it uploads the screenshots as the `build-output` artifact.

## Build it (on the Mac)

1. Install Xcode 26 (Liquid Glass; Xcode 16 also builds, with a material fallback) from the App Store, and XcodeGen: `brew install xcodegen`.
2. `cd` to this folder and run `xcodegen generate`. It makes `Nursery.xcodeproj`.
3. `open Nursery.xcodeproj`. Select the **Nursery** target → Signing & Capabilities → choose your Team.
   Do the same for the **NurseryWidget** target.
   If Xcode says that the bundle id is taken, change `cz.drabek.nursery` in `project.yml` (both targets), and run step 2 again.
4. Connect the iPhone with a cable, select it as the destination, and press Run (⌘R).
   On the first run, the iPhone asks you to trust the developer: Settings → General → VPN & Device Management.
5. On the first launch, allow **Local Network** (necessary) and **Notifications** (for the alert).

A free Apple ID works, but the app then stops after 7 days, and you must press Run again.
A paid developer account ($99/year) gives one year, and TestFlight lets your wife install it with no cable.

## What the server must give

The app needs no change on the Pi. It uses what already runs:

- go2rtc RTSP on port **8554**, with two streams of the camera: the main (high) stream and the sub (low)
  stream. Their names are in Settings (the developer's are `nursery`, 2K, and `nursery_sd`, 360p). The app
  asks for the main stream only when the picture is big (zoomed in, full screen); else the sub stream, which
  also serves the sound-only modes. The camera audio must be G.711 (A-law or µ-law).
- `http://<server>:1984/nursery/config.js` with `ptzWebhook` (and `powerWebhook` later). The app reads the ids from it, so no secret is in the app.
- The Home Assistant webhook on port **8123** (`automation nursery_ptz_webhook`).

The server address is in Settings; the initial value comes from `HomeDefaults`.

## Tests

Unit tests cover the pure code on both platforms: SDP, RTP and the H.264 depacketizer, G.711, the Digest
login of IP cameras, the pairing link, and the level meter. iOS: `NurseryTests/`, run with
`xcodebuild test -scheme Nursery` on a simulator. Android: `android/app/src/test/`, run with
`gradle testReleaseUnitTest`. CI runs both.

`Tools/rtsp_check.py` is a line-by-line Python copy of the protocol code of the app (`RTP.swift` and the
RTSP steps). It connects to go2rtc, rebuilds the H.264 frames, and checks them with ffmpeg. It also checks
the G.711 table against the decoder of ffmpeg, sample for sample.

```bash
python3 Tools/rtsp_check.py rtsp://192.168.0.136:8554/nursery 10
python3 Tools/rtsp_check.py "rtsp://192.168.0.136:8554/nursery?audio" 5
```

## The acceptance test on the iPhone

1. Open the app. The picture comes in under 2 s. Clap. You hear it at the same time as you see it.
2. Lock the phone for 5 minutes. The sound continues. The lock screen shows "Nursery · Listening", with the bars.
3. Swipe home. The small window opens. The sound continues.
4. Turn off the Wi-Fi of the phone for 30 s. The alert comes. Turn it on. The sound returns by itself.
5. Pinch to zoom, and slide to each edge. Double tap resets it.
6. Tap each arrow. The camera moves the correct way. If not, change the sign in the `VEL` map of `/config/nursery_ptz.py` on the Pi.
7. Night mode: the screen is black, and the waveform still moves.

## Files

| Path | What it does |
|---|---|
| `Nursery/Stream/RTSPClient.swift` | RTSP over TCP (Network.framework). It uses interleaved RTP, a keepalive, and timeouts. |
| `Nursery/Stream/RTP.swift` | SDP, RTP, H.264 depacketizing (single, STAP-A, FU-A), and the G.711 tables. |
| `Nursery/Stream/VideoRenderer.swift` | H.264 → CMSampleBuffer → `AVSampleBufferDisplayLayer` |
| `Nursery/Stream/LiveAudioPlayer.swift` | G.711 → AVAudioEngine. It keeps a bounded jitter queue, the gain, and the meter. |
| `Nursery/Stream/MonitorEngine.swift` | The connection life cycle, the reconnect, the background mode, and the sound state. |
| `Nursery/Playback/SystemIntegration.swift` | Now Playing, the Live Activity, the alert, and picture in picture. |
| `Nursery/UI/*` | The SwiftUI screens. |
| `NurseryWidget/` | The Live Activity for the lock screen and the Dynamic Island. |
| `Tools/` | The protocol check, and the icon drawing script. |
| `Nursery/App/HomeDefaults.swift`, `android/…/HomeDefaults.kt` | The developer's home addresses and stream names: the only place with them. |
| `NurseryTests/`, `android/app/src/test/` | The unit tests of the pure code. |
