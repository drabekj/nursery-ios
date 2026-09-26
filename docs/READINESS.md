# Chůvička: ready for other people?

Written 26 Sep 2026 on the branch `readiness`, after a review of all the Swift and Kotlin code, the
workflows and the README. It answers one question: can strangers use this app, and what must change
first. It is opinionated. Severity: **must** before a stranger installs it, **should** soon after,
**could** later.

## The verdict

- **Phone-to-phone is general.** The pairing link, the Bonjour name, the RTSP server on the baby phone
  and the client are the same on both platforms and assume nothing about the developer's home. What is
  missing is not generality but safety: a deep link re-pairs silently, and the wrong-code lockout can lock
  the real parents out (see Security).
- **The camera path is general enough, now.** Quality is modelled as the camera's main stream and sub
  stream, not "2K and 360p", with the same adaptive behaviour (main stream only for a big picture, sub
  stream otherwise, sub stream on a hot phone, sub stream with a hidden picture for sound only). The
  stream names and the addresses are settings. The developer's values are the initial values, in one
  file per platform (`Nursery/App/HomeDefaults.swift`, `android/.../HomeDefaults.kt`); a public build
  empties them and deletes nothing else.
- **Two things are still the developer's own.** The Home Assistant pan/tilt on iOS (webhook ids from a
  config file that go2rtc serves; Android has none), and the README, which is a lab notebook of one
  home. Both are isolated and harmless for others, but not features for others.
- **Distribution is not possible yet.** iOS needs the paid developer program. Android has an APK, but no
  versioning, no licence, and no privacy text. See Distribution.

## Done on this branch

- Main stream / sub stream naming, comments, log lines and the two quality titles, both platforms.
- `HomeDefaults` on each platform; named go2rtc ports (8554, 1984) and the Home Assistant port.
- The Home Assistant config is asked only with go2rtc, and not at all when the config path is empty.
- The connect line of the iOS log no longer carries the camera password or the pairing code.
- "+" in a room name is percent-encoded in the iOS pairing link (Android read it as a space).
- Unit tests, both platforms: SDP, RTP, H.264 depacketizer and packetizer round trip, G.711 (all 256
  codes against a reference), the Digest login (RFC 2617 example), the pairing link, `Reach.split` and
  the Tailscale test, the level meter. The Digest code and the Android pairing parser were made pure
  for this, with the same behaviour. CI runs them: `xcodebuild test` on a simulator, `gradle
  testReleaseUnitTest` before the APK.
- The Android wizard no longer claims the app is in the App Store or Google Play.

Nothing was compiled here (no Xcode, no Gradle on this machine). The first CI run of the branch is the
compile check.

## Must, before strangers use it

Security of the phone-to-phone mode (unencrypted RTSP on the LAN, guarded by a 6-digit code):

1. **Confirm a pairing link.** Any QR code, web page or NFC tag with `chuvicka://pair?…` re-pairs the
   parent at once and reconnects (`NurseryApp.swift` `.onOpenURL`, `MainActivity.kt`). A parent can be
   switched to a fake "baby". Show the name and the addresses, and ask. Also accept only private IPv4
   addresses in `a=`, and only ASCII digits in the code (iOS accepts any Unicode digit).
2. **Lock out per client, not the whole server.** After 10 wrong codes in a minute all requests fail for
   a minute (`BabyServer.swift`, `BabyServer.kt`). Any device on the Wi-Fi can keep the parents locked
   out, and two stale parents retrying after "Nový kód" do it by themselves. Count per address, and never
   block an address that has authenticated.
3. **Say what the protection is.** In Help and in the store text: private on a trusted home Wi-Fi; the
   code travels in clear in every request; anyone who can sniff the Wi-Fi (guest network, a compromised
   device) can see and hear; Tailscale adds encryption away from home. Longer term: a 128-bit secret and
   a TLS fingerprint in the QR code.
4. **Cap connections and idle sessions** on the baby server (Android starts two threads per socket).

Correctness:

5. **Android `BabyService` returns `START_STICKY`.** After a system restart of the service, a
   camera/microphone foreground service starts from the background, which Android 14+ refuses. Use
   `START_NOT_STICKY` and tell the user in the notification that the broadcast stopped.
6. **The Android baby microphone loop** continues on a read error (`BabyCapture.kt` ~229): back off,
   restart the `AudioRecord`, log it.
7. **The Photo button on iOS** shows for a direct RTSP camera and always fails (photos come only from
   the go2rtc API). Hide it, or take the last decoded frame locally on both platforms (better: then it
   works for every source).

Legal and store:

8. **A LICENSE file.** Without one nobody may redistribute the code. Pick MIT, Apache-2.0 or GPL-3.0.
   Add a NOTICE for zxing and AndroidX (Apache-2.0).
9. **A privacy policy page** (one paragraph is enough: nothing leaves the phone) and a "not a medical
   device, do not rely on it alone" line in Help and the store text.
10. **Version numbers.** iOS `CURRENT_PROJECT_VERSION` and Android `versionCode` are `1` forever, and CI
    replaces the rolling `android-latest` release on every push to master. Derive the build number from
    the CI run number or a tag, and publish tagged releases with notes.

## Should

Product:

- **Only Czech.** Every string is inline in code; the locale is pinned to `cs_CZ`. For strangers in
  Czechia this is fine. For anyone else: an iOS String Catalog and Android `strings.xml`, with English.
  Do it before the strings grow further; it is the biggest mechanical change on the list.
- **"iPhone" in text shown on iPads and about Android baby phones** (`PairingView`, `BabyUnitView`,
  `SettingsView`, `NightView`, `VolumeWarning`). Say "telefon".
- **Ports are fixed** (8554, 1984, 8123). Accept `host:port` in the server field.
- **Tailscale is detected by the address range 100.64/10**, which is also carrier NAT on mobile data.
  Call it "the remote address" in the UI, or detect the interface.
- **mDNS name collisions.** Everyone's baby phone is "Pokojíček". Two of them on one Wi-Fi and the parent
  reaches the wrong one, gets 401, and feeds the lockout. Put a stable unit id in the TXT record and the
  QR code, and resolve by it.
- **The Home Assistant pan/tilt** is a developer feature. Make it an opt-in integration (a URL and a
  webhook id in Settings) or drop it from the public build. `HomeDefaults.configPath` already switches it
  off when empty.
- **App Review needs a way in without hardware.** Demo mode is a launch argument only. Add a hidden
  in-app demo, and review notes for background audio and the microphone.
- **The README** should become a user guide (local network permission, guest Wi-Fi and client isolation,
  both phones on one Wi-Fi, the charger, remote access), with the developer notes in `docs/`.

Code quality (the app is small enough that this is a few days, not weeks):

- **`MonitorEngine.swift` (873 lines) and Android `object Monitor`** mix route choice, retries, the
  audio session, stream policy (detail, heat, night), alerts and the watchdog. Split out a pure
  `StreamPolicy` (which URL, given view, heat and setting: it is now testable), a `RouteResolver`, and the
  alert policy. Make `Monitor` a class with its dependencies passed in.
- **One page per file** in `OnboardingView.swift` (672), `Wizard.kt` (708), `ParentScreen.kt` (510),
  `MonitorParts.swift` (479).
- **The two platforms have drifted.** iOS detects sound against an adaptive noise floor with a
  sensitivity setting; Android uses a fixed threshold. The brand tables, the route order, the backoff and
  the hint texts are copied by hand. Write `docs/PROTOCOL.md` (the pairing link, the Bonjour record, the
  RTSP paths, `?audio`, `X-Chuvicka-Addresses`, the 401 rules, timeouts) and shared JSON fixtures that both
  test suites read.
- **Duplicates:** the "saved addresses, then Bonjour" loop is in `Pairing.swift` and `MonitorEngine.swift`;
  the Tailscale test closure is repeated four times on iOS; Android `ConnectionTest.testClient` re-does
  `Monitor.open` without the LAN-first sort.
- **Dead code** (checked with grep): iOS `CameraControl.power`/`powerID`/`powerReady` (the "power
  later" webhook), `Theme.Card`, `cardStroke`, `Theme.background`, `skyBottom`, `H264Depacketizer.droppedFrames`,
  `NurseryActivityAttributes.room`; Android `H264Depacketizer.parameterVersion` (written, never read);
  `Artwork.png` is identical to `AppIcon.png`.
- **Settings are stringly keyed:** thirty `didSet { d.set(forKey:) }` blocks on iOS, and Android repeats
  the key at every `Settings.set(flow, "key", v)` call. A `Pref<T>` that owns its key and default removes
  the class of typo that silently loses a setting.
- **Silent failures:** the Keychain `SecItemAdd` status is ignored; Android swallows exceptions in the
  server I/O loops and in the alert permission. Log them.
- **Naming:** the brand is "Nursery" in the Xcode target, bundle id and logger, and "chuvicka" in the
  Android package and the URL scheme. `BabyService` is the Bonjour constants on iOS and a foreground
  service on Android. `Source.camera` covers both go2rtc and a direct camera; `{phone, go2rtc, ipCamera}`
  would say what it is. Sound mode `.off` is labelled "Ztlumeno" (muted).
- **More tests, next:** the baby server's auth, lockout and SETUP parsing (extract pure functions), the
  route choice, `SoundActivity` with an injected clock, the backoff, the `onboarded` migration, and an
  in-process server-to-client loopback on each platform.

Wire-protocol details where the platforms differ (none breaks pairing today):

- Room name limits: iOS 63 UTF-8 bytes after NFC, Android 40 characters. One shared rule.
- The Android parent recognises a baby phone by the URL prefix `rtsp://chuvicka/`; iOS by a non-nil
  endpoint. Make it an explicit flag.
- `frame.jpeg` with no picture: 503 on iOS, 401 on Android (looks like a wrong code).
- Liveness timeouts: 8 s on Android, 6 s on iOS; neither server enforces `timeout=60`.
- iOS keeps the last `WWW-Authenticate` header, so a camera that offers Digest then Basic gets the
  password as Base64; Android prefers Digest.

## Could

- The commits carry a work e-mail as the author in a public repo; use a noreply address from now on.
- Android allows cleartext traffic globally; it is needed only for the snapshot call. Document it, or
  use a network security config for private ranges.
- iOS: exclude the Moments photos from the iCloud backup, or say that they are backed up.
- Android: an adaptive launcher icon; `dataExtractionRules` to keep the camera password and the codes
  out of device backups, and a Keystore-wrapped password instead of a plain private file.

## Distribution: what each platform needs

**iOS.** A free Apple ID installs for 7 days by cable, to the developer's own devices, and that is all.
To give the app to anyone else: the Apple Developer Program ($99 a year), then TestFlight (up to 10 000
external testers, a light review) or the App Store (a full review). Before that: set `DEVELOPMENT_TEAM`;
settle the bundle id (`cz.drabek.nursery`) and the name; add `PrivacyInfo.xcprivacy` to the app and the
widget (UserDefaults CA92.1, file timestamps C617.1; no tracking); set `ITSAppUsesNonExemptEncryption =
NO` (MD5 for the camera login is exempt); remove `NSAllowsArbitraryLoads` (`NSAllowsLocalNetworking`
covers the LAN HTTP, and RTSP on Network.framework is outside ATS); answer App Privacy as "Data Not
Collected"; a privacy policy URL; review notes and a way for the reviewer to see the app without a
camera; iPad screenshots, or drop the iPad. Ad-hoc distribution (100 devices by UDID) also needs the
paid program.

**Android.** A signed APK from the GitHub release `android-latest` already installs anywhere; that is a
real channel for friends. For Google Play: the developer account (a one-time fee), an AAB with Play App
Signing, `targetSdk` at Play's current minimum (verify in the console; 35 may already be one behind), the
Data safety form, a privacy policy URL, a video and a justification for the camera, microphone and media
foreground service types, and `START_NOT_STICKY` (above). For F-Droid: a LICENSE, tagged reproducible
builds and store metadata; every dependency is Apache-2.0, so it is feasible.

## Roadmap, in order

1. Security of the phone-to-phone mode: the pairing confirmation, the per-client lockout, the honest
   text. Version numbers and tagged releases. LICENSE, NOTICE, the privacy page. (Must, about a week.)
2. The Android `START_STICKY` and microphone loop, the Photo button, the "iPhone" wording, the wizard and
   Help text for strangers. (Must and should, a few days.)
3. `StreamPolicy` and `RouteResolver` out of `MonitorEngine`/`Monitor`, with tests; `docs/PROTOCOL.md`
   with shared fixtures; the dead code and the duplicates. (Should, about a week.)
4. Localisation to a String Catalog and `strings.xml`, English second. (Should, several days.)
5. The paid Apple program and TestFlight; the Play listing. (When the owner decides to spend.)
