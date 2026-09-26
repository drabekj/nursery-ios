#!/usr/bin/env bash
# Screenshots of the demo mode on the emulator. The demo shows a still picture and a fake sound.
set -u
APP=cz.drabek.chuvicka
mkdir -p shots
adb install -r app.apk
for p in POST_NOTIFICATIONS CAMERA RECORD_AUDIO; do adb shell pm grant $APP android.permission.$p || true; done
adb shell settings put global window_animation_scale 0
shot() {   # shot <file> <screen>
  adb shell am force-stop $APP
  adb shell am start -W -n $APP/.MainActivity --ez demo true --es screen "$2" >/dev/null
  sleep 8
  adb exec-out screencap -p > "shots/$1.png"
  echo "shot $1"
}
for s in parent aim sound muted volume night night-controls stop settings settings-advanced remote help baby baby-live; do shot "$s" "$s"; done
# The room state: Klid, Pláče, Nehlídá, Připojuji…, Ozývá se muted; the band in Pláče; Night mode in Pláče.
for s in klid sound-cry sound-lost sound-connecting sound-muted main-cry night-cry; do shot "$s" "$s"; done
for s in wizard wizard-role wizard-source wizard-camera wizard-test; do shot "$s" "$s"; done
shot parent-dark parent-dark
shot sound-dark sound-dark
shot paused paused
adb logcat -d -s Chuvicka AndroidRuntime:E > shots/logcat.txt || true
