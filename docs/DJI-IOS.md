# DJI Mic 3 on iOS — what it needs, what is built

Written 2026-10-07. Companion to `DJI-STATUS.md` (Android and hardware facts).
The target phone is Mason's iPhone "Wolverine" (iOS 27, USB-C, team
`YLRF842M22`). Nothing here has run on it yet.

## Short version

iOS does not need a separate Bluetooth stack or an accessory protocol for
either DJI route. Both a transmitter in Bluetooth mode and the receiver on
USB-C are ordinary **AVAudioSession input ports** (`.bluetoothHFP` and
`.usbAudio`). The app already captures a Bluetooth HFP mic this way for the
Ray-Ban Meta glasses, so the DJI listening path on iOS is the same shape with
a second port type allowed. That path is now written in Swift (see "Built
tonight"); it compiles, it is registered, and it has not been run.

File import off a transmitter is the Files-app route and needs no native
code; it is untested on iOS.

## Why each Apple framework does or does not apply

| Framework | Needed? | Why |
|---|---|---|
| **AVAudioSession / AVAudioEngine** | Yes, and it is all that is needed for listening | A Bluetooth transmitter pairs as a hands-free (HFP) headset; iOS exposes it as an input port once the session category allows Bluetooth HFP. A USB audio class device on a USB-C iPhone appears as a `.usbAudio` port with no extra entitlement. The engine taps the input node and converts to 16 kHz PCM16. |
| **CoreBluetooth** | No | CoreBluetooth is BLE/GATT. The DJI link is Bluetooth Classic HFP, which apps cannot touch directly on iOS; the OS owns the pairing and the SCO link. There is no DJI GATT audio characteristic. The app's existing `bluetooth-central` background mode is for the Omi wearable, not for this. |
| **External Accessory (MFi)** | No | Only for MFi accessories speaking a custom protocol over Lightning/USB. USB Audio Class is handled by the system, so a UAC receiver needs no `UISupportedExternalAccessoryProtocols` entry. |
| **AudioDriverKit / USB host APIs** | No | Not available to third-party iOS apps anyway; UAC is the only sanctioned USB audio path. |
| **UIDocumentPicker (via `file_picker`)** | Yes, for file import | iOS Files can browse a USB mass-storage drive on a USB-C iPhone. The picker copies each chosen file into the app sandbox before Dart sees it, the same constraint as Android's `file_picker` copy. |

### Limits that are real on iOS

- **Bluetooth HFP is 8 or 16 kHz narrowband/wideband**, same as Android; the
  resample-to-16 kHz step hides which one the link negotiated. DJI's own cap
  for this mode (16 kHz / 16-bit) is the ceiling.
- **Only one HFP route at a time.** iOS routes the whole session to the
  chosen input. With two transmitters paired, only one carries audio, which
  matches DJI's own note.
- **Capture pauses on a phone call or Siri.** Handled as `interrupted`, with
  one resume attempt when the system says it may resume.
- **Lightning iPhones** would need the Camera Adapter for USB; Wolverine is
  USB-C, so the receiver and a transmitter plug straight in.
- **No battery or link-quality data** for an HFP or USB input; the device
  row shows the link kind and connection state only, as on Android.
- The session category is `playAndRecord` with `.allowBluetoothHFP`. Omi's
  own phone-mic engine and the Ray-Ban engine also configure the shared
  session; the Dart capture layer runs one source at a time, so they do not
  fight, but the first thing to check if audio is silent is which engine last
  set the category.

## Built tonight (2026-10-07)

| File | What |
|---|---|
| `app/ios/Runner/DjiMic/DjiMicAudioCapture.swift` | Lists `.bluetoothHFP` and `.usbAudio` inputs; routes to the chosen one; taps and converts to PCM16 mono 16 kHz; reports route loss, interruption, interruption-ended and engine config change. |
| `app/ios/Runner/DjiMic/DjiMicHostApiImpl.swift` | Implements the Pigeon `DjiMicHostApi`: `getAvailableInputs`, `start`, `stop`, `isRecording`. State machine mirrors Android's `DjiMicController`: idle → starting → running; route loss or interruption → interrupted → one rebuild → running or idle with `route_lost` / `rebuild_failed` / `resume_failed`. Error codes on start: `permission_denied`, `input_unavailable`, `route_failed`, `engine_start_failed`. |
| `app/ios/Runner/AppDelegate.swift` | Registers the host API next to the phone-mic and Ray-Ban ones. |
| `app/ios/Runner.xcodeproj/project.pbxproj` | The `DjiMic` group with the three Swift files, in both the Runner and RunnerRayBanDat targets. |
| `app/lib/services/devices/discovery/dji_mic_discoverer.dart` | `isSupported` now true on iOS as well. |

Verification done: the three Swift files typecheck with `swiftc -typecheck`
against the iOS SDK and Flutter framework (no errors, no warnings); the Dart
change passes `flutter analyze`; the Xcode project file lints. Not done: a
full `flutter build ios` (CocoaPods are not installed in this checkout), and
any run on a device.

## What remains, with sizes

| Step | Size | Notes |
|---|---|---|
| 1. First iOS build and install on Wolverine | 1–2 h | `pod install`, dev scheme (`com.friend-app-with-wearable.ios12.development`), set the team to `YLRF842M22` for the local build only, install over USB from Xcode. The project's checked-in team is `9536L8KLMP` (upstream's); do not commit a team change. Explain each step to Mason in one line as it happens. |
| 2. Bluetooth listening on the phone | 30 min of Mason's time | Same five-minute test as Android (`DJI_PHONE_TEST.md`): pair the transmitter in iOS Settings → Bluetooth, pick it in the app, talk. Silent = route never engaged; chipmunk = converter fed the wrong rate. Logs: Console.app filtered on the app, or `idevicesyslog`. |
| 3. USB listening (receiver on USB-C) | 0 code, 15 min of Mason's time | The same Swift path. Open question is only whether iOS lists the DJI receiver as `.usbAudio` and accepts it as a preferred input. |
| 4. File import | 1–3 h if it misbehaves, 0 if it works | The import page is not platform-gated. Risks: `file_picker` on iOS may hand back a security-scoped URL the page reads before the copy finishes; multi-select from an external drive in Files is slower than from On My iPhone. Test with two short takes first. |
| 5. Background capture | 1 h | `UIBackgroundModes` already has `audio`; confirm the HFP route survives the screen locking, which Ray-Ban testing suggests it does. |
| 6. Permission copy | 15 min | `NSMicrophoneUsageDescription` in `Info.plist` is upstream's text about "Bugs"; it is what Mason will read when iOS asks. Worth a plain sentence before any TestFlight build. |
| 7. Pigeon regeneration guard | 0 | `dart run pigeon --input lib/dji_mic_interface.dart` rewrites `DjiMicPigeon.g.swift` in place; the Xcode project already points at it, so regeneration needs no project edit. |

Nothing in this list touches the backend, the desktop, or the Watch.
