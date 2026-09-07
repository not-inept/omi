# DJI Mic on the Omi desktop app

The desktop app is not a thin client — the macOS app is a full Swift/SwiftUI
capture client with its own WAL, its own uploader and its own audio stack — so
"document what it would take instead" was not available as an escape. This is
what is actually true today, read out of the code, and what first-class
handling would cost.

Nothing here has been run against a DJI receiver. Everything below is read from
source; the claims that need hardware are marked.

## What already works, with no code change at all

**The receiver on USB-C is already selectable as the capture microphone.**

`Sources/MainWindow/Pages/Settings/Sections/MicrophonePickerCard.swift`
enumerates every Core Audio input device on the machine and lets the user pin
one, storing it by UID (`DefaultsKey.preferredMicrophoneDeviceUID`) because
Core Audio device IDs are not stable across reconnects. It is deliberately not
a curated list — it shows what the system shows.

A DJI receiver is a USB audio class device. macOS gives every such device a
Core Audio entry with a name and a UID like any built-in or USB interface, so
it appears in that picker as "DJI MIC 3 RX" (or whatever the unit reports)
alongside the MacBook's own microphone. Selecting it routes ambient capture
through the receiver, and therefore through whichever transmitters are linked
to it.

Better than that: `Sources/Audio/PreferredMicrophoneReconnect.swift` already
watches `kAudioHardwarePropertyDevices` while transcription is live and
re-pins the preferred device when it reappears. That was written for Ray-Ban
Meta glasses reconnecting over Bluetooth, but it is UID-based and device
agnostic — unplugging the receiver and plugging it back in mid-session should
re-pin it on its own.

*Needs hardware:* that the receiver enumerates with a stable UID across
replugs on this Mac, and that its name is recognisable in the list.

**A transmitter's recordings are already reachable, just not inside Omi.** A
transmitter plugged into a Mac mounts as a normal FAT32 volume under
`/Volumes`, with `TX_MIC*` folders at its root. Two sibling projects in this
lab already read exactly that layout: `labs/dji-mic-controller` (inventory,
30-minute split-chain detection, non-destructive merge, offline transcription)
and `labs/notewell` (auto-detects mounted transmitters, copies takes off,
transcribes them). Either can put a WAV on disk today.

## What "first class" would still cost

Two gaps, in the order they are worth closing.

### 1. Label the receiver rather than leaving it anonymous — written, unseen

`PickerInputDevice` already carried `isBluetooth` and the card already said in
plain language that a Bluetooth mic runs at voice quality. A DJI receiver
deserves the opposite note: it is the *high* quality path (48 kHz / 24-bit per
DJI's specs, where a transmitter paired straight to a phone over Bluetooth is
capped at 16 kHz / 16-bit).

Written and building, never looked at by a person on a screen:
`AudioCaptureService.isDjiMicName()` alongside the existing
`isMetaGlassesName()`, and a `DJI` badge with the line *"DJI Mic receiver on
USB-C — full-quality audio from its transmitters"* in
`MicrophonePickerCard.swift`. Tests in
`Desktop/Tests/DjiMicInputNamingTests.swift`. The mobile app does the same
thing — see `djiMicLinkLabel` in
`app/lib/services/devices/discovery/dji_mic_discoverer.dart`.

*Needs hardware:* what the receiver's product name actually is. The match is
"dji" and "mic" in the same name, which is loose on purpose.

### 2. Import a mounted transmitter's recordings — not built

This is the real work, and it is the desktop mirror of what the mobile app now
does in `app/lib/services/dji_mic_import_service.dart`.

What exists to build on:

| Piece | Where |
|---|---|
| WAL entry model and its upload filename | `Sources/OmiWAL/WALModel.swift` — `WALEntry.generateFileName()`, `normalizedForUpload` |
| WAL lifecycle and cloud sync | `Sources/WAL/WALService.swift`, `WALCloudSyncLogic.swift` |
| The upload itself | `Sources/Generated/OmiApi.generated.swift` → `syncLocalFilesV2V2SyncLocalFilesPost` |
| Job reconciliation | `Sources/WAL/WALSyncReconciler.swift` |
| A device-driven bulk import already shaped like this | `Sources/WAL/StorageSyncService.swift` |

What is missing:

- **Volume detection.** Watch `NSWorkspace.didMountNotification` for a volume
  with `TX_MIC*` folders at its root. `labs/notewell`'s `recorders.py` is the
  reference for the rule (folder-shape detection, never a hardcoded volume
  name — someone else's transmitter is not called FIZZBO).
- **WAV decode and downsample to 16 kHz mono PCM16.** On macOS this is
  `AVAudioConverter`/`AVAudioFile` rather than the hand-written filter the
  phone needs, so it is smaller than the Dart version — but the same three
  traps apply: read the real byte rate from the header (a 32-bit float take is
  4 bytes a sample, not 3), low-pass before decimating, and chunk to about
  three minutes so a job finishes inside the backend's stale-job window.
- **A screen.** Settings, or a sheet raised by the mount notification. The
  mobile page (`app/lib/pages/settings/dji_mic_import_page.dart`) is the model:
  list takes with their own timestamps, mark what is already imported, group
  only a confident 30-minute device cut, and never write to the transmitter.
- **Import bookkeeping.** A `DefaultsKey` holding the same
  `<file name>|<byte size>` set the phone keeps. The desktop and the phone do
  not share it, so importing the same take on both makes two conversations —
  worth stating in the UI rather than solving.

Rough size: 600–900 lines of Swift plus tests, most of it the screen. The
audio work is small because AVFoundation does the resampling.

### Not worth doing

**A shared import history between phone and desktop.** It would need a backend
collection and a sync path for what is, in practice, "did I already plug this
mic into this machine". Say it in the UI instead.

**Windows/Electron.** `desktop/windows` is a separate Electron app with its own
capture stack. The receiver will appear in its input-device list through the
browser's `enumerateDevices` for the same reason it does on macOS; the import
flow would be a third implementation. Not attempted, not investigated beyond
that.

## Build

The macOS app builds from `desktop/macos`:

```bash
xcrun swift build -c debug --package-path Desktop   # the pre-push gate
./run.sh                                            # full app, needs signing
```

Both were run on 2026-09-07: a cold build of the whole package took 331 s and
finished clean on Xcode 26.2, and the incremental rebuild with the change above
took 36 s. There is one pre-existing linker warning about Homebrew's
`libwebp.7.dylib` being built for a newer macOS than the app's 14.0 target;
it is not related to this work.

`desktop/macos/README.md` is the authority on the rest — it pins CI to Xcode
16.4 while this machine has Xcode 26.2, so a clean local build here is not
proof CI is happy and vice versa.
