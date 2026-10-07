# DJI Mic on the Omi desktop app

The desktop app is not a thin client — the macOS app is a full Swift/SwiftUI
capture client with its own WAL, its own uploader and its own audio stack — so
"document what it would take instead" was not available as an escape. This is
what is actually true today, read out of the code, and what first-class
handling would cost.

Nothing here has been run against a DJI receiver. Everything below is read from
source; the claims that need hardware are marked.

## The test tomorrow: hands-free listening (7 October 2026)

The app is installed at `~/Applications/Omi.app` (this fork, signed with the
Joy Quest team certificate so its permissions survive rebuilds). It is a
separate app from the official one in `/Applications/omi.app`; both can be
open at once. Everything below was built on 7 October and run on this Mac
without a DJI receiver plugged in, so the receiver-specific lines are the
expected behaviour, not a thing I watched happen.

1. **Open `~/Applications/Omi.app` and sign in** with your Omi account. The
   first launch asks for the microphone once; say yes. (It is a new app to
   macOS, so it asks once more even though the official Omi already has it.)
2. **Plug the DJI receiver into the Mac's USB-C port.** macOS treats it as a
   USB microphone; nothing to install.
3. **Settings → Transcription → Microphone.** The receiver should appear in
   the list with a `DJI` badge and the line "DJI Mic receiver on USB-C —
   full-quality audio from its transmitters". Click it. The choice is
   remembered by the device's own id, so unplugging and replugging it, or a
   restart, keeps it. (If the name macOS shows for it does not contain both
   "DJI" and "Mic", it still works, it just has no badge — tell me the name
   it shows and I will match it.)
4. **Settings → General → Hands-free.** Flip the switch on. This is the mode
   you described: it turns Audio Recording to Always On and Always Respond
   on, in one go, and keeps them that way. If the receiver is plugged in and
   you skipped step 3, the switch pins it for you.
5. **What you should see.** The line under the switch is the state:
   - "Listening on DJI MIC 3 RX and answering what it hears" (or whatever
     the receiver calls itself) — working.
   - "Starting…" for a second or two while the session opens.
   - "Paused — not listening. Resume to continue" after you press Pause.
   - "Chosen microphone not connected — listening on MacBook Pro Microphone
     until it comes back" — the receiver is unplugged or asleep. Capture
     falls back to the Mac's mic and swaps back on its own when the
     receiver reappears.
   - "Microphone permission required" — say yes to the prompt, or System
     Settings → Privacy & Security → Microphone.
   The listening dot in the top bar says the same thing in short:
   "Hands-free · DJI MIC 3 RX", "Hands-free paused", "Hands-free · mic
   missing".
6. **Talk to a transmitter.** Say something addressed to Omi — "Omi, what's
   on my calendar today?" The text should appear in the live transcript and,
   about a second after you stop talking, Omi answers through the same path
   the push-to-talk key uses. Plain conversation that is not addressed to it
   is transcribed but not answered. Only your own voice triggers an answer
   (the backend's speaker tag), so a second person on the other transmitter
   is recorded but not answered.
7. **Pause and resume.** Press Pause on the card, or click the listening dot
   in the top bar — while hands-free is on, that click is Pause/Resume
   rather than the usual Off → Always On → Only Meetings cycle. The mic
   closes while paused; nothing is recorded.
8. **Turn it off** with the switch. That also turns Always Respond off and
   Audio Recording to Off, so "off" means off. The microphone choice stays.

What to tell me afterwards: the exact name the receiver shows in the list,
whether the answer came within a couple of seconds, and anything that was
said and not transcribed. If the receiver never appears in the list, run
`system_profiler SPAudioDataType` in Terminal and send me the output.

What this does not do yet: import recordings off a transmitter (the
`DJI_AUDIO` folder) on the desktop — that is the second half of this
document and is still not built.

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

### 7 October 2026: what it took to build and install on this Mac

- Xcode is now 27.0 (27A266a), Swift 6.4. The package built clean on it.
- `webp` and `pkgconf` had gone missing from Homebrew (the `CWebP` system
  library target needs `pkg-config libwebp`); `brew install webp pkgconf`
  restored them. `pcre2` (for the bundled ripgrep) was already present.
- Cold `xcrun swift build -c debug --package-path Desktop`: the dependency
  fetch dominated (Sentry's xcframeworks alone are 473 MB); the compile
  itself was 73 s. Incremental: about a second.
- Tests touching this work:
  `xcrun swift test --package-path Desktop --filter 'HandsFreeListeningTests|AlwaysRespondGateTests|DjiMicInputNamingTests|PreferredMicrophoneReconnectTests'`
  — 27 tests, 0 failures (11 of them new, for the hands-free state and wording).
- Packaging and install: `OMI_APP_NAME="Omi Dev" OMI_SIGN_IDENTITY=<sha1 of the
  Joy Quest "Apple Development: Mason Robert Cooper" certificate> ./run.sh --yolo --no-wait`,
  then the bundle was moved from `/Applications/Omi Dev.app` to
  `~/Applications/Omi.app` and re-signed with
  `labs/mrc-lib/best-practices/apple/sign-mac-app.sh` so its designated
  requirement names the bundle id and the team rather than one build's hash
  (see `stable-code-signature.md` there). Pass the identity by SHA-1: the
  Keychain holds two certificates with that name, one expired in 2024, and a
  name match is ambiguous. Bundle id stays `com.omi.desktop-dev`.
- `--yolo` means the dev Cloud Run backend with production Firebase
  identities: the app signs into Mason's real Omi account and writes real
  conversations. There is no local backend in this setup.

### What hands-free is, in code

`Desktop/Sources/Audio/HandsFreeListening.swift` — the pure state and wording
(`HandsFreeListening`) and the defaults writer (`HandsFreeListeningSettings`).
It is Always On + Always Respond + the pinned microphone behind one switch:
`enable` pins a connected DJI receiver when no mic is chosen, then sets both
settings; `pause` sets the recording mode to Off and remembers the pause;
`resume` and `reconcileAtLaunch` (called from `AppState.init`) put it back.
`HandsFreeListeningCard.swift` is the Settings → General card (switch, status
line, Pause/Resume, "Use <receiver>" when one is plugged in but not chosen);
it enumerates Core Audio inputs with the same observer the microphone picker
uses, so "chosen microphone not connected" is live. `CaptureListeningLogic`
makes the top-bar listening control a Pause/Resume while the switch is on
and names the state in its title and tooltip. Capture fallback when the
receiver is unplugged, and re-pinning when it returns, were already there
(`startMicCaptureIfNeeded`, `PreferredMicrophoneReconnectMonitor`).
