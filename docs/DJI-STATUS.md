# DJI Mic in this fork — state of play

Written 2026-09-07 by reading and running the fork, not from notes.

This is Mason's fork of [BasedHardware/omi](https://github.com/BasedHardware/omi)
(`origin` = `not-inept/omi`), on branch `feat/dji-mic-3`, seven commits ahead of
the upstream commit it branched from (`c9a1c38b45`, 2026-08-20). It is a linked
git worktree; `labs/omi-quest/omi` holds the shared `.git`.

**Nothing in the DJI work has ever run on real hardware.** Everything below is
either "builds and passes tests on this Mac" or "read from source". The parts
that need a transmitter in hand are marked, and there are a lot of them.

---

## 1. The hardware, as DJI documents it

Checked against DJI's own pages rather than assumed. The code's behaviour
follows from these.

| Claim | Status | Source |
|---|---|---|
| The transmitters record internally; the receiver has no storage | **Confirmed.** 32 GB on a Mic 3 transmitter, ~27.9 GB usable, no card slot | DJI Mic 3 specs / FAQ |
| Internal recording is 24-bit and 32-bit float, dual-file | **Confirmed.** Both written at once: `_orig` (raw) and `_edit` (voice preset, low cut, noise cancellation, adaptive gain applied) | DJI Mic 3 FAQ |
| File naming | **Confirmed and matches this fork's parser.** Folder `TX_MIC001_20250530_115001`, file `TX01_MIC002_20250527_202904_orig.wav` | DJI Mic 3 FAQ |
| A recording is auto-cut every 30 minutes | **Confirmed on real Mic hardware** by the sibling project `labs/dji-mic-controller` — every automatic split measured at 1800.15 s across 69 real takes. Never observed on a Mic 3 specifically | `labs/notewell/notewell/recorders.py`, `labs/dji-mic-controller/README.md` |
| Recordings come off over USB-C as a mounted drive | **Confirmed.** DJI's instruction is to connect the transmitter (or the charging case) to a computer and copy out of `DJI_AUDIO` | DJI Mic 3 FAQ, Mic 2 manual |
| A transmitter pairs straight to a phone over Bluetooth as a microphone | **Confirmed.** Hold the linking button two seconds, pair as an ordinary Bluetooth device | DJI Mic 3 beginner's guide |
| That Bluetooth link is limited | **Confirmed, and it matters.** Max 16 kHz / 16-bit, "similar to Bluetooth headsets", against 48 kHz / 24-bit through the receiver. Third-party apps only — not the system camera. **Two transmitters can pair to a phone, but only the first one connected records** | DJI Mic 3 FAQ |
| The receiver is a USB audio class device on phones and computers | **Not stated in DJI's FAQ in those words**, but it is the standard behaviour the compatibility list assumes and what the desktop mic picker would surface. Unverified on hardware |
| Wireless transfer of internal recordings | **Exists — but only for DJI.** The Mic 3 FAQ names a File Download feature in the DJI Mimo app, over the transmitter's own link. There is no published protocol and no SDK: DJI's developer programme covers aircraft, gimbals and the Cloud API, not the Mic line | DJI Mic 3 FAQ, developer.dji.com |

**So: USB-C is the transfer path and Bluetooth is the listening path.** A
wireless import would mean reverse-engineering Mimo's link — capturing its
traffic against a transmitter, recovering the framing and the file-read
commands, and reimplementing them with no guarantee across firmware updates.
That is a research project, not a feature, and it is not attempted here.

---

## 2. What builds on this Mac

Toolchain found on this machine:

| | |
|---|---|
| Flutter | **3.44.5** (Dart 3.12.2), the repo's FVM pin at `app/.fvm/flutter_sdk` — *not* the Homebrew Flutter on `PATH` |
| JDK | Homebrew's `java` is 11, which is too old for this AGP. Gradle uses Android Studio's bundled JBR at `/Applications/Android Studio.app/Contents/jbr/Contents/Home`, which Flutter finds on its own |
| Android SDK | `~/Library/Android/sdk`; `adb` at `~/Library/Android/sdk/platform-tools/adb` (not on `PATH`) |
| Xcode | 26.2 (build 17C52). The desktop README pins CI to Xcode 16.4, so a clean local build here is not proof CI is happy |

### Mobile app — builds, tests pass

```bash
cd app
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"   # the pin, not Homebrew

flutter analyze lib/utils/dji_mic_wav.dart lib/utils/dji_mic_recordings.dart \
  lib/utils/dji_mic_import_registry.dart lib/services/dji_mic_import_service.dart \
  lib/pages/settings/dji_mic_import_page.dart \
  lib/services/devices/discovery/dji_mic_discoverer.dart

flutter test test/unit/dji_mic_wav_test.dart test/unit/dji_mic_import_test.dart \
  test/unit/dji_mic_recordings_test.dart test/unit/dji_mic_link_kind_test.dart \
  test/unit/audio_source_test.dart

dart run pigeon --input lib/dji_mic_interface.dart     # regenerates the contract

flutter build apk --debug --flavor dev \
  --dart-define=OMI_APP_PROFILE=local_dev \
  --dart-define=OMI_API_BASE_URL=http://192.168.0.168:8000/ \
  --dart-define=OMI_FIREBASE_AUTH_EMULATOR_HOST=192.168.0.168
```

The IP is this Mac's LAN address; check it with `ipconfig getifaddr en0` and
rebuild if it has moved.

Android unit tests (the Kotlin half) run through Gradle:

```bash
cd app/android && ./gradlew testDevDebugUnitTest --tests 'com.friend.ios.djimic.*'
```

### One build trap that cost two builds today

`app/build/` had sixteen files duplicated with a ` (1)` suffix — the signature
of a file-sync tool resolving a conflict, and this tree lives under `~/sync/`.
R8 then fails with *"Type … is defined multiple times"*, naming a `.class` and
its ` (1).class` twin. It looks like a code problem and is not one.

```bash
find app/build -name "* (1).*"        # if this prints anything, that is why
```

Remove or move those aside and build again. The source tree itself is clean —
only build output was affected.

### Desktop (macOS)

```bash
cd desktop/macos
xcrun swift build -c debug --package-path Desktop   # the pre-push gate
./run.sh                                            # full app; needs a signing identity
```

Both were run today: a cold build of the whole package took 331 s and finished
clean, an incremental rebuild 36 s. `docs/DJI-DESKTOP.md` covers what is and is
not there — briefly: **the receiver on USB-C is already selectable as the
capture microphone with no code change at all**, because the desktop's mic
picker enumerates every Core Audio input by UID; it is now labelled as a DJI
receiver rather than left anonymous in the list; and importing a mounted
transmitter's recordings is not built, with the file-by-file cost of building
it written down there.

### Backend

Not exercised for this work, and deliberately: the whole DJI feature is
client-side, so nothing here needs a backend change to build or to test. Its
own tooling is `make setup-backend` / `make dev-up` from the repo root, and the
dev harness is `scripts/dev-harness/dev-up.sh`.

There is one backend-side gap, already flagged in the code
(`app/lib/services/capture/conversation_source_for_device.dart`): the backend's
`ConversationSource` enum has no `dji_mic_3` member, so a DJI conversation is
labelled `unknown` rather than rejected. Provenance only; audio and transcripts
are unaffected.

---

## 3. What the DJI work actually is now

Four commits landed before today (Aug 21 – Sep 1), three today.

### Listening: a transmitter paired over Bluetooth

Built earlier, unchanged today. `DeviceType.djiMic3` is a device type beside
the Omi wearable, with its own Pigeon contract
(`app/lib/dji_mic_interface.dart`) and an Android Kotlin module
(`app/android/app/src/main/kotlin/com/friend/ios/djimic/`):

- `DjiMicBluetoothRoute` routes system audio input to the paired transmitter —
  `AudioManager.setCommunicationDevice` on API 31+, `startBluetoothSco()` on
  29–30.
- `DjiMicCaptureEngine` opens an `AudioRecord` on
  `VOICE_COMMUNICATION`, asking for 16 kHz and falling back to 8 kHz.
- `DjiMicResampler` normalises whatever the SCO link negotiated to a fixed
  16 kHz mono PCM16, so Dart never sees the variability.
- Dart side: `DjiMicDiscoverer` → `DjiMicTransport` → `DjiMicDeviceConnection`
  → `DjiMicSource`, feeding the same capture, WAL and transcription path the
  phone mic uses.

The list is deliberately unfiltered — anything the OS reports as a
communication-device mic appears, with a likely DJI sorted first — because
there is no DJI-specific discovery protocol and a renamed transmitter must
still be findable.

### Listening: the receiver on USB-C — new today

The route only ever listed `TYPE_BLUETOOTH_SCO` inputs, so half the hardware
was invisible. It now also lists USB audio class inputs and can route to one.
Details in the commit; the two things worth knowing here:

- USB inputs have no Bluetooth address and their `AudioDeviceInfo.id` is
  reassigned on every replug, so identity is a `usb:<id>:<product name>` token
  that matches on id within a session and on name after a replug.
- Route-loss used to be judged by comparing addresses, which would have
  reported every USB route as lost the instant it engaged. It now compares
  device ids.

The device list says which link a row is: "Connected by USB-C" or "Paired over
Bluetooth · 16 kHz link". Both rows can appear for the same hardware at once,
which is why they are labelled.

Below API 31 there is no `setCommunicationDevice`, so USB inputs are not
offered rather than offered and then failing to route.

### File transfer — new today

`Settings → Import → DJI Mic` (`app/lib/pages/settings/dji_mic_import_page.dart`).
Plug a transmitter in, pick takes out of its `DJI_AUDIO` folder through
Android's own file picker, and they become conversations:

1. The filename is parsed for the transmitter's own start time.
2. The WAV header is read for the real format — **never a hardcoded byte
   rate**; a 32-bit float take is 4 bytes a sample where a 24-bit take is 3,
   and assuming the 24-bit rate overstates a float file's length by a third,
   which silently breaks 30-minute chunk detection.
3. The audio is decoded and downsampled to 16 kHz mono PCM16 through a
   windowed-sinc low-pass. Naive decimation would fold everything above 8 kHz
   back into speech range; sibilants live up there.
4. It is written into the WAL directory in three-minute chunks, each with its
   own start time, and handed to `LocalWalSync.addExternalWal` — the same door
   the SD-card and flash-page syncs use. No new endpoint; nothing added to the
   backend.
5. What has been imported is remembered on the phone. **Nothing is ever
   written to the transmitter** — no marker, no rename, no delete.

Only a confident 30-minute *device* cut is stated as one take. A quick manual
stop/restart looks identical from outside, so the UI says what it saw rather
than what it means — the line `labs/notewell` and `labs/dji-mic-controller`
both hold.

### Tests

| Suite | Count | What it holds down |
|---|---|---|
| `test/unit/dji_mic_wav_test.dart` | 15 | Header walking (`LIST` chunks, `WAVE_FORMAT_EXTENSIBLE`, RF64 refusal), all four sample formats landing on one amplitude, the 15 kHz tone that must not alias to 1 kHz, chunk-boundary determinism |
| `test/unit/dji_mic_import_test.dart` | 20 | Chunking and offsets, the WAL filename the backend parses, two transmitters at the same second staying separate, a float take not measured a third long, failed imports leaving nothing behind, the registry |
| `test/unit/dji_mic_recordings_test.dart` | 24 | Filename parsing and split-chain detection (pre-existing) |
| `test/unit/dji_mic_link_kind_test.dart` | 6 | The Bluetooth/USB link kind surviving serialization |
| `test/unit/audio_source_test.dart` | 49 | Audio source framing, `DjiMicSource` included (pre-existing) |
| `android/…/DjiMicInputUidTest.kt` | 8 | USB uid round-trip and replug rematch |
| `android/…/DjiMicResamplerTest.kt` | 7 | The SCO resampler (pre-existing) |
| `desktop/…/DjiMicInputNamingTests.swift` | 3 | The desktop receiver name match, and that it does not collide with the Ray-Ban Meta match |

Every fixture is synthetic and says so in the file. None of it substitutes for
a run against hardware.

---

## 4. What is not verified, which is most of it

Nothing in this list can be settled without the mics and the phone.

**Bluetooth listening**
- That the transmitter pairs to the phone with the headset/hands-free profile
  and appears as a communication device at all.
- That the SCO route engages. A silent recording means it did not.
- That the resampler is on the right path. Chipmunk audio means it was bypassed.
- Whether a real route loss (transmitter powered off) recovers as designed.

**USB listening — every part of it**
- That the receiver enumerates as an available *communication* device on
  Mason's phone, not merely as an output.
- Which of `TYPE_USB_DEVICE` / `TYPE_USB_HEADSET` / `TYPE_USB_ACCESSORY` it
  reports as.
- That `setCommunicationDevice()` accepts it and `AudioRecord` opens on it.
- That the product name is stable enough to rematch after a replug.

**File transfer**
- That Android mounts a DJI transmitter over USB-C OTG at all, and that it
  shows up in the system file picker.
- That `file_picker`'s read stream works over a USB volume's content URI
  without copying the whole file into the app's cache first.
- What a real 32-bit float DJI file's header looks like — in particular
  whether it declares itself as plain IEEE float or as
  `WAVE_FORMAT_EXTENSIBLE`. Both are handled; which one arrives is unknown.
- Whether a genuine 30-minute automatic cut on a **Mic 3** behaves like the
  cuts measured on the older units. `labs/dji-mic-controller` says its
  30-minute chunk has still never been observed live on any unit — every real
  take so far was started and stopped by hand.
- Whether the backend accepts recordings dated days or weeks back, or refuses
  them with `backfill_lookback_exceeded`. Importing old takes is the whole
  point of the feature, so this is the one worth checking first.

**Battery and richer link state.** Not implemented, and not obviously
implementable: Android exposes no public API for a Bluetooth headset's battery
level, and a USB audio device has none to report. The device row shows the link
kind and the connection state, which is what the platform actually offers.

---

## 5. What needs Mason

Two steps, both physical, in this order.

1. **Install the debug APK and pair a transmitter in Bluetooth mode.**
   `DJI_PHONE_TEST.md` is the full checklist — the dev harness to start first,
   the two failure signatures to watch for (silent = the route never engaged;
   chipmunk = the resampler was bypassed), and the `adb logcat` filter.

2. **Plug the receiver into USB-C, then plug a transmitter in for transfer.**
   The receiver should appear in the app's device list as a second DJI row
   labelled "Connected by USB-C". The transmitter should appear in Android's
   file picker as a drive with a `DJI_AUDIO` folder, reachable from
   `Settings → Import → DJI Mic`.

Neither needs anything from the backend. The dev build signs in against the
local harness; a real-backend build needs `FIREBASE_SERVICE_ACCOUNT_KEY`.
