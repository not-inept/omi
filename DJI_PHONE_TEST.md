# DJI Mic 3 — first phone test

None of the DJI work has **ever run on a device**. This is the checklist for
the first real test: install the APK, then three things in order — pair a
transmitter over Bluetooth, plug the receiver into USB-C, and plug a
transmitter in to transfer its recordings.

`docs/DJI-STATUS.md` is the fuller picture: what DJI's own documentation
confirms, what builds, and everything that cannot be verified without the
hardware in hand.

## The APK

```
app/build/app/outputs/flutter-apk/app-dev-debug.apk
```

- Debug build, dev flavor (`com.friend.ios.dev`), debug keys only.
- Rebuilt 2026-09-07 with the USB-input and file-import work in it.
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

## Test 1 — pair the transmitter over Bluetooth

There are now three separate things to try, and this is the first. The
Bluetooth path is **not** the USB path: your transmitters mount as
FIZZBO / MAGGY over USB-C, which is mass storage for the on-device recordings
and is Test 3 below.

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
| The USB receiver row never appears | Same cause on the USB side: Android is not listing it among `getAvailableCommunicationDevices()`. Note whether it is TYPE_USB_DEVICE or TYPE_USB_HEADSET if you can see it anywhere else. |
| A transmitter plugged in for transfer never shows in the file picker | Android did not mount it as USB mass storage. Check Android's Files app — if it can't see it either, the phone isn't supplying OTG power or the cable is charge-only. |

Whatever happens, the logcat capture plus one line per symptom is a complete
report.

## Test 2 — the receiver on USB-C

Plug the **receiver** (not a transmitter) into the phone's USB-C port, with the
transmitters linked to it as normal.

Open the same connect-device flow. The receiver should appear as a second DJI
row, labelled **Connected by USB-C** where the paired transmitter's row says
*Paired over Bluetooth · 16 kHz link*. Both can be listed at once; that is why
they are labelled. Select the USB one and start capture.

This path has never run at all, so the useful report is simply which of these
happened:

| What you see | What it means |
|---|---|
| No USB row at all | Android is not reporting the receiver as an available *communication* device — the assumption the whole USB path rests on. Note whether Android's own volume/audio UI sees it |
| A row appears, capture fails to start | The route refused. `adb logcat -s DjiMic DjiMic.Route DjiMic.Controller` will say `input_unavailable` or `route_failed` |
| Capture runs and transcribes | Working. Compare it to the Bluetooth path — the receiver carries 48 kHz/24-bit against Bluetooth's 16 kHz/16-bit cap, so it should sound noticeably better |

Then unplug and replug it mid-session: the app re-matches a USB input by
product name after a replug (the OS renumbers it), and that rematch is
untested.

## Test 3 — transfer recordings off a transmitter

Plug a **transmitter** in over USB-C (or put it in the charging case and plug
that in). Android should mount it as a drive.

In the app: **Settings → Import → DJI Mic**. Tap *Choose recordings*, and in
Android's file picker navigate to the transmitter and its `DJI_AUDIO` folder.
Multi-select a couple of short takes and import them.

What should happen: a list showing each take with the time the transmitter
started recording and its length, anything already imported marked as such,
then an import that turns them into conversations dated when they were
recorded — not when they were imported. They upload and transcribe like any
other recording, so watch them in Sync.

Nothing is written to the transmitter. Ever.

Worth trying deliberately:

- **An old take**, a week or more back. The backend refuses recordings older
  than its recovery window (`backfill_lookback_exceeded`), and importing old
  material is the point of the feature — so this is the single most useful
  thing to find out.
- **A take longer than 30 minutes**, if one exists. DJI cuts them
  automatically; the list should say "part 2 of 3, 30-minute cut" and the
  parts should land back to back in one conversation.
- **A 32-bit float take.** Its length in the list must match the real one — a
  third too long means the header read is wrong.
- **Re-picking the same folder** after importing. Everything already taken
  should be marked *Imported* and unticked.

## Rebuild (if the Mac's IP changed)

```bash
cd app
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"   # Flutter 3.44.5, not the Homebrew one
flutter build apk --debug --flavor dev \
  --dart-define=OMI_APP_PROFILE=local_dev \
  --dart-define=OMI_API_BASE_URL=http://<mac-ip>:8000/ \
  --dart-define=OMI_FIREBASE_AUTH_EMULATOR_HOST=<mac-ip>
```
