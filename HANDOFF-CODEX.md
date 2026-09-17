# Handoff to Codex — DJI Mic 3 fork of Omi

> Superseded by [HANDOFF.md](HANDOFF.md) (the lab-wide handoff standard); kept here for full history.

Written 2026-09-08. Mason is handing this fork to Codex today. Read this
before touching anything; `docs/DJI-STATUS.md` and `docs/DJI-DESKTOP.md` are
the deeper detail this note points at rather than repeats.

## 1. What this fork is, and why

This is Mason's fork (`origin` = `not-inept/omi`) of
[BasedHardware/omi](https://github.com/BasedHardware/omi), branch
`feat/dji-mic-3`, branched from upstream `c9a1c38b45` (2026-08-20). It is a
linked git worktree — `labs/omi-quest/omi` holds the shared `.git`.

The idea: Mason owns a DJI Mic 3 kit (two transmitters, one receiver) and
wants to use it as Omi's listening device instead of — or alongside — the
phone's own mic, both on the phone and on the desktop. DJI Mic 3 publishes no
SDK for the Mic line (their developer program covers drones/gimbals only), so
every path here rides platform-generic audio APIs rather than a DJI
integration:

- **Listening on the phone, two ways.** A transmitter pairs to the phone
  directly over Bluetooth Classic (HFP/SCO, capped at 16 kHz/16-bit — "similar
  to Bluetooth headsets" per DJI's own FAQ). Or the receiver plugs into the
  phone's USB-C port as a USB audio class device (48 kHz/24-bit, the
  full-quality path). Both are just OS-level "communication device" audio
  routes — nothing DJI-specific about the wiring.
- **File import off the transmitter over USB.** A transmitter records
  internally (32 GB, no card slot) and mounts as a plain FAT32 drive over
  USB-C. The app reads its `DJI_AUDIO` folder through the system file picker,
  decodes and downsamples the WAVs, and imports them as conversations dated
  when they were actually recorded — no wireless path exists (DJI's Mimo app
  has one, but it's unpublished and unSDK'd).
- **Listening on the desktop.** The receiver already worked as a Mac input
  device with zero code (Core Audio treats it like any other USB mic) — this
  fork only added a label ("DJI Mic receiver on USB-C — full-quality audio")
  so it's not anonymous in the picker. Desktop file import is designed
  (`docs/DJI-DESKTOP.md`) but not built.
- **The Always Respond desktop toggle** (last commit, unrelated to DJI) is a
  separate feature: Settings → General gets a toggle that, when Always On
  listening is active, answers an ambient transcript segment that reads as
  addressed to the assistant through the same path push-to-talk uses. It
  landed on this branch because it was the day's other piece of work, not
  because it depends on DJI hardware.

## 2. Exact state — every commit, one line each

Newest first, all ten on `feat/dji-mic-3` (`git rev-list --count
c9a1c38b45..feat/dji-mic-3` = 10; `git status -sb` shows only this untracked
file, and there is no `origin/feat/dji-mic-3` ref — nothing on this branch has
been pushed anywhere). Note: `docs/DJI-STATUS.md` says "seven ahead" and the
2026-09-07 card comment says "five commits" — both are stale, written before
later commits landed same-day; the table below is current.

| Commit | Summary |
|---|---|
| `4bfa3c8172` | desktop: Always Respond toggle beside Always On listening (unrelated to DJI) |
| `c5f18ec7ed` | fix: a dual-file (`_orig`/`_edit`) take imports as one conversation, not two; import now starts the upload immediately |
| `51bb27765e` | desktop: label the DJI receiver in the mic picker; add `docs/DJI-DESKTOP.md` and `docs/DJI-STATUS.md` (state of the whole fork) |
| `02498fc5d1` | mobile: import recordings off a DJI transmitter over USB-C — WAV decode, windowed-sinc downsample, WAL chunking, upload |
| `cdecedcd0a` | mobile: the DJI receiver on USB-C is a listening device too (USB audio class inputs), not just a Bluetooth-paired transmitter |
| `a72f543a12` | chore: commit the Sep 1 build fixes (Kotlin/AGP opt-outs) and `DJI_PHONE_TEST.md` that were sitting uncommitted |
| `65f0363d74` | fix: five correctness bugs from an independent review of the first three commits (device-info branch, route-start ordering, session-id race, AudioManager.mode guard) |
| `1f3655fe3e` | mobile: port DJI Mic filename/30-minute-chunk-chain parsing logic from the sibling `labs/dji-mic-controller` CLI tool |
| `0c95df90eb` | mobile: wire `DeviceType.djiMic3` through the device/capture pipeline (Dart side) |
| `3401f8b1dc` | mobile: DJI Mic 3 Pigeon contract + native Android Kotlin capture engine (Bluetooth SCO route, resampler) |

**What is built:** the full Bluetooth-listening path, the full USB-listening
path, the full USB file-import path (all mobile/Android), the desktop
mic-picker label, and the desktop Always Respond toggle. All pass their own
test suites (Dart, Kotlin, Swift) and all builds are clean on this Mac.

**What has run on hardware: nothing has touched a real DJI receiver or
transmitter.** Per `docs/DJI-STATUS.md`, every claim about Bluetooth pairing,
SCO routing, USB enumeration, resampling correctness, and file-picker behavior
is either "read from DJI's own documentation" or "builds and passes synthetic
tests on this Mac" — none of it is confirmed against the actual mics. The one
piece of physical contact so far, per Mason: **the debug APK was installed
once on his S25** — installed only, not yet run through the
pairing/capture flow.

iOS is not wired at all for DJI Mic 3 — the Pigeon contract generates an iOS
stub (`DjiMicPigeon.g.swift`) but there's no Swift host implementation behind
it. This is Android-only today.

## 3. How to run

**Desktop (macOS):**
```bash
cd desktop/macos
./run.sh --yolo
```
`--yolo` targets the deployed dev Cloud Run backend — **this is Mason's real
account against production Firebase identities and production data stores**,
not a sandbox (`desktop/macos/README.md`). Use a named bundle
(`OMI_APP_NAME=...`) for isolated state if testing something disposable; don't
treat `--yolo` state as throwaway.

**Phone (Android), from `DJI_PHONE_TEST.md`:**
```bash
# 1. Start the dev harness so the phone can reach it over LAN
OMI_DEV_HOST=192.168.0.168 scripts/dev-harness/dev-up.sh   # check with ipconfig getifaddr en0 — rebuild if the IP moved

# 2. Install (adb is not on PATH)
~/Library/Android/sdk/platform-tools/adb -s R5CY50KXJWL install -r \
  app/build/app/outputs/flutter-apk/app-dev-debug.apk

# 3. Rebuild if needed (Flutter 3.44.5 via the repo's FVM pin, not Homebrew's Flutter)
cd app
export PATH="$PWD/.fvm/flutter_sdk/bin:$PATH"
flutter build apk --debug --flavor dev \
  --dart-define=OMI_APP_PROFILE=local_dev \
  --dart-define=OMI_API_BASE_URL=http://<mac-ip>:8000/ \
  --dart-define=OMI_FIREBASE_AUTH_EMULATOR_HOST=<mac-ip>
```
`R5CY50KXJWL` is Mason's S25's adb serial. Full three-test checklist (pair
Bluetooth, plug USB receiver, transfer files) with failure signatures and a
logcat filter is in `DJI_PHONE_TEST.md`.

Nothing on this branch has been pushed to any remote and nothing has run
against real hardware yet — the phone test above is the next concrete step,
still outstanding as of this handoff.

## 4. Mason's goal for today

Verbatim: **"learning how to and attempting to make 2 contributions to omi:
mobile support for the dji mic as input"** — the second contribution isn't
named yet.

### Contribution 1: mobile support for the DJI mic as input

This already exists on the branch — commits `3401f8b1dc`, `0c95df90eb`,
`1f3655fe3e`, `65f0363d74`, `cdecedcd0a` are it (listening, not the desktop
work or Always Respond). Where the change lives, from `app/AGENTS.md`'s own
DJI section:

| Layer | Files |
|---|---|
| Pigeon contract | `app/lib/dji_mic_interface.dart` → generated `app/lib/gen/dji_mic_pigeon.g.dart` + `app/ios/Runner/DjiMic/DjiMicPigeon.g.swift` (stub, unimplemented) + `app/android/app/src/main/kotlin/com/friend/ios/djimic/DjiMicPigeon.g.kt` |
| Android native capture | `app/android/app/src/main/kotlin/com/friend/ios/djimic/` — `DjiMicController`, `DjiMicCaptureEngine`, `DjiMicBluetoothRoute`, `DjiMicResampler`, `DjiMicInputUid`, `DjiMicEventEmitter`, `DjiMicHostApiImpl` |
| Dart device wiring | `DeviceType.djiMic3` in `app/lib/backend/schema/bt_device/bt_device.dart`; `app/lib/services/devices/transports/dji_mic_transport.dart`, `.../connectors/dji_mic_connection.dart`, `.../discovery/dji_mic_discoverer.dart`; `app/lib/services/audio_sources/dji_mic_source.dart`; `app/lib/services/capture/capture_controller.dart` and `conversation_source_for_device.dart` |
| File import (USB transfer) | `app/lib/utils/dji_mic_recordings.dart` (filename/chunk-chain parsing) → `app/lib/utils/dji_mic_wav.dart` (WAV header/decode/downsample) → `app/lib/services/dji_mic_import_service.dart` (WAL chunking + upload trigger) → `app/lib/utils/dji_mic_import_registry.dart` (bookkeeping) → `app/lib/pages/settings/dji_mic_import_page.dart`, reached from `import_history_page.dart` |
| Tests | `app/test/unit/dji_mic_*.dart` (recordings, wav, import, link_kind), `app/test/unit/audio_source_test.dart`, Kotlin `DjiMicResamplerTest.kt` + `DjiMicInputUidTest.kt` |

**What upstream's `CONTRIBUTING.md` / `docs/doc/developer/Contribution.mdx`
require before a PR is even worth opening:**

- Check product fit against `PRODUCT.md` and the invariant registry
  (`docs/product/invariants/`) first — this is a new device type, additive,
  doesn't appear to touch a locked invariant, but confirm before opening.
- A feature this size ("large or ambiguous") should ideally start as a GitHub
  issue so BasedHardware maintainers align on direction before/alongside the
  PR — not strictly required for a well-scoped PR, but worth doing given this
  adds a whole new device class.
- Fork the *actual* repo (`github.com/BasedHardware/Omi`, not this local
  `not-inept/omi` fork) via GitHub's Fork button, or push this branch to a
  personal fork of the real upstream and PR from there.
- Before pushing: draft the PR body, run `make preflight`, then
  `scripts/pr-preflight --pr-body-file <path>` (or `--suggest` first for the
  paste-ready invariant/failure-class section). This validates invariant
  citations and any required `Failure-Class:` declaration.
- PR body must show verification commands and their output — "it compiles" is
  explicitly called out as not evidence.
- Regression tests for bug fixes; core-path + main-error-path tests for new
  features (already present here per the commit messages' own verification
  sections — Dart, Kotlin, and Swift suites all cited).
- `app/AGENTS.md`'s own DJI section (quoted above) is already the doc update
  this PR needs — it was added in commit `65f0363d74` for exactly this
  reason ("this change should have shipped with it in the first place").

**How to open the PR against `BasedHardware/omi` from this fork:**
1. Add the real upstream as a remote if not already present, or push this
   branch to a personal GitHub fork of `BasedHardware/omi`.
2. `git push <personal-fork-remote> feat/dji-mic-3` (or a cleaner subset —
   see "what would make it mergeable" below on whether to split it).
3. Open the PR from that fork's branch against `BasedHardware/omi:main` via
   `gh pr create` or the GitHub UI, following the steps in
   `docs/doc/developer/Contribution.mdx`.
4. Note in the PR body: no product invariant paths are touched (confirm
   against `docs/product/invariants/` before asserting this), and this is a
   `feat:` not a `fix:`, so no `Failure-Class:` declaration is required.

**What would make it mergeable — the real gaps:**
- **No tests have run against real hardware, ever.** Every test in the
  suites listed above is synthetic/fixture-based (the commit messages say so
  explicitly). Maintainers reviewing a new device-input class will very
  likely want confirmation it works on actual DJI hardware before merge —
  this is the single biggest gap. Today's phone test (`DJI_PHONE_TEST.md`)
  is exactly the step that produces that evidence.
- **No Mason-specific code in the production DJI source files** — checked
  by grep across `dji_mic_interface.dart`, every Dart file under
  `services/devices/{transports,connectors,discovery}` and
  `services/audio_sources`/`dji_mic_import_service.dart`, the utils files, the
  import page, the desktop Swift (`AudioCaptureService.swift`,
  `MicrophonePickerCard.swift`), and the Kotlin module: no hardcoded IPs,
  device names, or personal identifiers. The LAN IP and adb serial in this
  handoff and `DJI_PHONE_TEST.md` are local test-instructions text, not code.
  One thing that IS Mason-specific: two **test fixture files**,
  `app/test/unit/dji_mic_recordings_test.dart` and
  `dji_mic_link_kind_test.dart`, use `FIZZBO`/`MAGGY` — Mason's own
  transmitters' nicknames, carried over verbatim from the sibling
  `labs/dji-mic-controller` project's real measured recordings (a genuine
  30-minute auto-split, a real 2-second gap, etc.). This is fixture data
  encoding real timing behavior, not personal info leakage, but it would read
  as odd to an upstream reviewer — worth a one-line comment in the PR
  explaining what they are, or renaming the fixtures to something generic
  before submitting.
- **A device-agnostic USB-audio input path — already true, and it's the
  stronger claim than "matches by name."** Mobile *discovery* itself is
  deliberately unfiltered: `cdecedcd0a` and `docs/DJI-STATUS.md` both say any
  input the OS reports via `getAvailableCommunicationDevices()` as a
  communication-device mic appears in the list — a renamed or non-DJI USB/BT
  communication mic would show up too. The `"dji"+"mic"` substring match
  (`looksLikeDjiMic3`) only affects sort order (likely-DJI first) and the row
  label, on mobile; on desktop the same substring match (`isDjiMicName()` in
  `AudioCaptureService.swift`) only decides the badge/label text, not whether
  the device is selectable — it already was, for any Core Audio input. This
  is a genuine strength for mergeability: reviewers can see it's not gated
  behind DJI-only logic at the capability layer, only at the cosmetic layer.
- **iOS is unimplemented.** The Pigeon contract generates an iOS stub but
  there's no Swift host behind it — maintainers may ask whether this PR
  should be Android-only-and-say-so, or block on iOS parity. Worth stating
  explicitly in the PR body rather than leaving as a silent gap.
- **The known correctness gaps already documented should probably be called
  out in the PR body, not just in `docs/DJI-STATUS.md`:** the backend has no
  `dji_mic_3` value in its `ConversationSource` enum (falls back to
  `unknown` — provenance-only, not a functional break, flagged with a TODO
  in `conversation_source_for_device.dart`); and the `AudioManager.mode`
  guard in `DjiMicBluetoothRoute.kt` is a partial mitigation against
  cross-subsystem ownership with `PhoneCallsPlugin.kt`, documented as a known
  gap rather than fully solved.
- **`4bfa3c8172` (the Always Respond desktop toggle) must not ride along.**
  It has nothing to do with the DJI mic and would confuse a reviewer looking
  at a "mobile DJI mic input" PR. Cherry-pick the DJI commits onto a clean
  branch off upstream `main` rather than pushing `feat/dji-mic-3` as-is.
- **Consider splitting further.** The full DJI portion of the branch also
  carries file-import (USB transfer) and the desktop receiver-label work,
  which are separable contributions from "mobile support for the DJI mic as
  input" narrowly read as the listening/capture path. A tighter PR (just
  `3401f8b1dc` + `0c95df90eb` + `65f0363d74`'s fixes, maybe +`cdecedcd0a` for
  USB listening) is easier to review than the whole DJI stack at once, though
  `AGENTS.md`'s PR-size rule treats size as advisory, not a hard block.

### Contribution 2: not yet named

Mason hasn't said what it is. Don't guess or start it — surface this back to
him rather than picking something.

## 5. Laws that apply, and the card receipt

From `/Users/joyquest/sync/jq-reboot/labs/CLAUDE.md` (the lab-wide charter),
the ones that bind this handoff:

- **Law 1, NOTHING IS DELETED.** This is a linked worktree sharing a `.git`
  with `labs/omi-quest/omi` — don't run destructive git ops without checking
  `pm-experiment/REORG-SAFETY.md` first.
- **Law 2, SECRETS STAY OUT.** No keystores/.env/tokens get committed. The
  real-backend build needs `FIREBASE_SERVICE_ACCOUNT_KEY` from Mason, never
  hardcoded.
- **Law 3, PRIVATE MEANS PRIVATE.** This fork lives outside `not-inept` (it's
  a fork of an open-source project, not a private repo) — but never push to
  `BasedHardware/omi` or any shared/org remote without Mason's explicit go,
  per push. `AGENTS.md`'s own git section reinforces this: nothing lands on
  upstream `main` without explicit sign-off, and this repo's own rule is
  "never push or open PRs unless explicitly asked."
- **Law 4, RECEIPTS ON CARDS.** This handoff itself ends with a receipt on the
  `labs/omi-quest` Mortar card.
- **Law 10, ONLY THE OWNER CLOSES DESIGN.** Nothing in this fork has been
  seen working on real hardware — every report so far (and this one) says
  "ready for the owner's eyes," never "done" or "fixed."

**Card receipt rule:** `POST http://localhost:4600/api/decision` with key
`labs/omi-quest`, posting a comment via `{replace}` — done as part of this
handoff (see the report).
