# Omi DJI Mic 3 fork — handoff

Standard: [../../HANDOFF.md](../../HANDOFF.md). Full history before this
file: [HANDOFF-CODEX.md](HANDOFF-CODEX.md).

## State

Fork of `BasedHardware/omi` (`origin` = `not-inept/omi`), branch
`feat/dji-mic-3`, a linked git worktree sharing `.git` with
`labs/omi-quest/omi`. Ten commits ahead of upstream `c9a1c38b45`, none
pushed anywhere. Built: Bluetooth listening, USB listening, USB file
import (all Android), the desktop mic-picker label, and an unrelated
desktop "Always Respond" toggle. **Nothing has run against real DJI
hardware** — a debug APK was installed once on the S25 (`R5CY50KXJWL`),
not yet run through pairing/capture. iOS now has a Swift implementation of
the Pigeon contract (Bluetooth HFP and USB audio inputs through
AVAudioSession; typechecks, registered, never run) — plan and sizes in
`docs/DJI-IOS.md`. A fresh debug APK (2026-10-07, Mac IP 192.168.0.171) is
at `app/build/app/outputs/flutter-apk/app-dev-debug.apk`, not installed.

## Next

The phone hardware test in `DJI_PHONE_TEST.md` — pair Bluetooth, plug the
USB receiver, transfer files off a transmitter — still outstanding and
the single biggest gap before this is PR-worthy upstream.

## Verify

```
cd app && flutter test test/unit/dji_mic_recordings_test.dart test/unit/dji_mic_wav_test.dart test/unit/dji_mic_link_kind_test.dart
# ran 2026-09-17 via FVM flutter: "All tests passed!" (41 tests)
```

Kotlin/Swift suites cited in HANDOFF-CODEX.md were not re-run this session (unverified).

## Owner steps

- Name contribution 2 (Mason's own words, 2026-09-08: "2 contributions
  to omi," only the mic-input one is scoped).
- Run the phone hardware test from `DJI_PHONE_TEST.md` on the S25, or
  say who should.

## Log

2026-10-07 claude: 41/41 DJI dart tests pass; rebuilt the dev debug APK for the Mac's new IP (.171); S25 not reachable by serial over adb, APK left on disk; wrote the iOS Swift listening path (DjiMic/ in the Runner target) and docs/DJI-IOS.md; rewrote DJI_PHONE_TEST.md's owner part as a five-minute test and queued it as a Mortar action.
2026-09-17 claude: created HANDOFF.md from the lab standard, condensing HANDOFF-CODEX.md; ran the three DJI-specific dart test files (41/41 pass); no code changes.
2026-09-08 claude: fork handed to Codex — full state, mergeability gaps and the PR checklist in HANDOFF-CODEX.md.
