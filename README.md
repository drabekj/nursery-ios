# Nursery — a native iOS baby monitor for the Tapo TC72

A local-only iPhone app. It shows the nursery camera and plays its sound in real time. It continues on the
lock screen and in picture in picture. It uses no cloud service and no third-party code.

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

- **The live picture** in 2K, with hardware decoding. The delay is below 0.5 s on the LAN.
- **Pinch to zoom** (1–4×) with native momentum. Double tap zooms to the finger, and a second double tap resets.
  The zoom changes only your screen. It does not move the camera.
- **The live sound**, with a bounded delay. A network stall never adds a permanent delay, because the
  queue drops late audio.
- **A waveform of the last 6 seconds**, so you *see* a cry, also with the phone muted.
- **Loudness boost**: Normal, Loud (+12 dB), Max (+20 dB), with a soft limiter. It is for a quiet room.
- **The lock screen and the Dynamic Island** (a Live Activity): "Listening", the loudness bars, or "No sound".
  If the app stops, the activity turns stale after 30 s, so a dead monitor never looks alive.
- **An alert** when the app hears nothing for 20 s. It reconnects by itself (1, 2, 4, then each 8 s),
  and at once when the Wi-Fi returns.
- **Night mode** (the moon): the screen goes black at minimum brightness, and only a dim waveform stays.
- **Pan and tilt** with a direction pad. A tap moves one step, and a hold repeats. It works through the existing Home Assistant webhook.
- **Camera power** buttons. They appear only when the power webhook exists (the smart plug).
- **Battery care**: in the background with no small window, the app asks go2rtc for the sound only (`?audio`).
  Thus the 2 Mbit/s video stops, and the battery lasts the night.
- **Landscape**: the picture fills the screen, and the controls fade after 5 s.
- **An event log** (Settings → Event log). You can share it, and it helps to find a fault at 3 a.m.

## Build it (on the Mac)

1. Install Xcode 16 or later from the App Store, and XcodeGen: `brew install xcodegen`.
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

- go2rtc RTSP on port **8554**, with the streams `nursery` (2K) and `nursery_sd` (360p). The camera audio is G.711 A-law.
- `http://<server>:1984/nursery/config.js` with `ptzWebhook` (and `powerWebhook` later). The app reads the ids from it, so no secret is in the app.
- The Home Assistant webhook on port **8123** (`automation nursery_ptz_webhook`).

The server address is in Settings (the default is `192.168.0.136`). Change it there after the move to the HP server.

## The test of the protocol code

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
