# DJI Mic 3 — first phone test

The DJI Bluetooth-mic change (4 commits, independently reviewed) has **never
run on a device**. This is the checklist for the first real test: install the
APK, pair a transmitter, and see whether audio actually flows.

## The APK

```
app/build/app/outputs/flutter-apk/app-dev-debug.apk
```

- Debug build, dev flavor (`com.friend.ios.dev`), debug keys only.
- Built with Flutter 3.44.5 (the repo's FVM pin: `app/.fvm/flutter_sdk`).
- Baked-in config: `local_dev` profile, backend `http://192.168.0.168:8000/`,
  Firebase Auth emulator `192.168.0.168:9099` — that was this Mac's LAN IP at
  build time. Check it's still right with `ipconfig getifaddr en0`; if it
  changed, rebuild (command at the bottom).

## Before the phone: start the dev harness

The dev build signs in against the local harness, not the real backend. On the
Mac, from the repo root:

```bash
OMI_DEV_HOST=192.168.0.168 scripts/dev-harness/dev-up.sh
```

`OMI_DEV_HOST` makes the harness bind so the phone can reach it (it binds
loopback-only otherwise). Phone and Mac must be on the same Wi-Fi.

> Want to test against the real Omi backend instead? That's the
> `bash app/setup.sh android beta` build and it needs one thing from you:
> `FIREBASE_SERVICE_ACCOUNT_KEY`.

## Install

```bash
adb install -r app/build/app/outputs/flutter-apk/app-dev-debug.apk
```

or copy the APK to the phone, tap it, and allow the install-unknown-apps
prompt. It installs alongside the Play Store Omi app (different package id).

Open the app, sign in (harness auth — any test account it offers), and grant
**Microphone** and **Nearby devices / Bluetooth** permissions when asked. Both
are required; capture will refuse without them.

## Pair the transmitter

The Bluetooth path is **not** the USB path. Your transmitters mount as
FIZZBO / MAGGY over USB-C — that's mass storage for the on-device recordings,
and the app does not ingest those yet (filename/chunk logic exists in
`app/lib/utils/dji_mic_recordings.dart`, no import path). Tonight's test is
Bluetooth only.

1. Put the transmitter in Bluetooth pairing mode (per the DJI manual — on the
   Mic 3 transmitter it's the linking control held until the LED blinks blue;
   it must be unlinked from the receiver's own radio to talk to the phone).
2. Android **Settings → Bluetooth → Pair new device**. The transmitter shows
   up as an ordinary headset/hands-free device — usually named "DJI MIC 3
   …"; if a unit was renamed it may show as something else (FIZZBO/MAGGY).
   Pair it.
3. Confirm Android shows it connected for **calls/audio** (headset profile).

## Select it in the app

In the app's connect-device flow (onboarding "Find device", or Settings →
device pairing), the list now includes paired Bluetooth mics as **DJI Mic 3**
entries. Anything named like "DJI MIC" sorts to the top, but the list is
deliberately unfiltered — a renamed transmitter still appears; pick it by
name. Select it and start capture.

## What to expect

**Stream mode (the default):** the recording indicator runs and live
transcription appears as you talk into the transmitter (harness must be up —
transcription is a backend job). Audio arrives in Dart as clean 16 kHz mono
PCM regardless of what the Bluetooth link negotiated. Speaking into the
*phone* should NOT be picked up once the route engages — the transmitter is
the mic.

**Batch mode (Transcribe Later):** with the Transcribe Later toggle on, no
live transcript — capture writes local recordings and the session timer
counts up; recordings sync/transcribe when back online. Same audio path
underneath, so if stream mode works, batch mode exercises storage, not the
mic.

**Resilience checks worth 2 minutes:** power the transmitter off
mid-recording — the app should surface a route-lost/interrupted state, not
crash, and recover when it reconnects. A phone call mid-capture should also
be survived (capture yields; the module refuses to stomp call audio).

## Failure signatures — what to report

Capture logs while testing:

```bash
adb logcat -s DjiMic DjiMic.Route DjiMic.Controller
```

| Symptom | Likely meaning |
|---|---|
| Recording starts but **no audio frames / dead-silent transcript** | SCO route not engaged — the OS never switched the communication device to the transmitter. Look for `route_failed` or `DjiMic.Route: connect: refusing — AudioManager.mode is already …` (something else — a call, another app — holds the audio mode). |
| Audio arrives but sounds like a **chipmunk (fast/high)** or slow/low | Resampler bypassed — Dart is getting the raw 8 kHz SCO rate instead of resampled 16 kHz. That's a `DjiMicResampler` bug; note it, it's exactly what this test exists to catch. |
| `permission_denied` error on start | Microphone or Nearby-devices permission missing. |
| `input_unavailable` | The picked device is no longer paired/available — re-pair, re-scan. |
| `route_lost` mid-session | Transmitter powered off / out of range — expected behavior, but note whether the app recovered. |
| Device never appears in the app's list | Android doesn't report it as a communication device — check it paired with the headset profile (step 3 above). |

Whatever happens, the logcat capture plus one line per symptom is a complete
report.

## Rebuild (if the Mac's IP changed)

```bash
cd app
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"   # Flutter 3.44.5, not the Homebrew one
flutter build apk --debug --flavor dev \
  --dart-define=OMI_APP_PROFILE=local_dev \
  --dart-define=OMI_API_BASE_URL=http://<mac-ip>:8000/ \
  --dart-define=OMI_FIREBASE_AUTH_EMULATOR_HOST=<mac-ip>
```
