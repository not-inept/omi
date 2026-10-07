import Foundation

/// Hands-free listening: with a chosen microphone (the DJI Mic receiver on USB-C is the case this
/// was built for) Omi listens all the time and answers what it hears, without the push-to-talk
/// key. It is deliberately not a fourth recording policy. It is "Always On" + "Always Respond" +
/// the pinned microphone, bound together behind one switch, with one Pause button and one status
/// line that says what is actually happening — listening, paused, or the chosen mic is missing.
///
/// `HandsFreeListening` is the pure part: the state derivation and the wording, reachable from a
/// test without an `AppState`. `HandsFreeListeningSettings` is the part that writes defaults.
enum HandsFreeListening {
  enum State: Equatable {
    /// The switch is off. Push-to-talk and the ordinary recording policy apply.
    case off
    /// The switch is on, but macOS has not granted the microphone.
    case needsMicrophonePermission
    /// The switch is on and the user pressed Pause. Nothing is captured until Resume.
    case paused
    /// The switch is on and the session is opening (or the app is still starting up).
    case starting
    /// Capturing and answering. `micName` is the device actually open, when known.
    case listening(micName: String?)
    /// The pinned microphone is not connected. Capture falls back to the Mac's own input (see
    /// `AppState.startMicCaptureIfNeeded`), which `fallbackName` names when a session is open.
    case micMissing(fallbackName: String?)
  }

  /// - Parameters:
  ///   - preferredUID: the pinned microphone (`DefaultsKey.preferredMicrophoneDeviceUID`), or "".
  ///   - preferredDeviceIsPresent: whether that UID is in the current input-device list. `nil`
  ///     before the first enumeration completes — never report a missing mic from an empty list.
  static func state(
    enabled: Bool,
    paused: Bool,
    hasMicrophonePermission: Bool,
    isTranscribing: Bool,
    preferredUID: String,
    preferredDeviceIsPresent: Bool?,
    recordingInputDeviceName: String?
  ) -> State {
    guard enabled else { return .off }
    if paused { return .paused }
    guard hasMicrophonePermission else { return .needsMicrophonePermission }
    if !preferredUID.isEmpty, preferredDeviceIsPresent == false {
      return .micMissing(fallbackName: isTranscribing ? recordingInputDeviceName : nil)
    }
    return isTranscribing ? .listening(micName: recordingInputDeviceName) : .starting
  }

  /// The one line under the switch. Plain words, present tense, no reassurance.
  static func statusLine(for state: State) -> String {
    switch state {
    case .off:
      return "Off — Omi answers only when you press the push-to-talk key"
    case .needsMicrophonePermission:
      return "Microphone permission required"
    case .paused:
      return "Paused — not listening. Resume to continue"
    case .starting:
      return "Starting…"
    case .listening(let micName):
      if let micName, !micName.isEmpty {
        return "Listening on \(micName) and answering what it hears"
      }
      return "Listening and answering what it hears"
    case .micMissing(let fallbackName):
      if let fallbackName, !fallbackName.isEmpty {
        return "Chosen microphone not connected — listening on \(fallbackName) until it comes back"
      }
      return "Chosen microphone not connected — plug in the receiver"
    }
  }

  /// The short name the top bar shows for the listening control while hands-free is on.
  static func barTitle(for state: State) -> String {
    switch state {
    case .off: return "Off"
    case .needsMicrophonePermission: return "Hands-free · no mic access"
    case .paused: return "Hands-free paused"
    case .starting: return "Hands-free · starting"
    case .listening(let micName):
      if let micName, !micName.isEmpty { return "Hands-free · \(micName)" }
      return "Hands-free"
    case .micMissing: return "Hands-free · mic missing"
    }
  }

  /// What one click on the top-bar listening control does while hands-free is on.
  static func barClickTitle(paused: Bool) -> String {
    paused ? "Resume hands-free" : "Pause hands-free"
  }

  /// The DJI receiver to pin when the user turns hands-free on without having chosen a mic.
  /// Picks the first device whose name says DJI Mic; `nil` when none is plugged in, in which case
  /// the Mac's own input is used and the status line says which device is open.
  static func djiReceiver(in devices: [AudioCaptureService.InputDevice])
    -> AudioCaptureService.InputDevice?
  {
    devices.first { AudioCaptureService.isDjiMicName($0.name) }
  }
}

/// The persisted switch and pause flag, and the three settings they drive. Every write goes
/// through here so "hands-free on" can never disagree with the recording policy underneath it.
@MainActor
enum HandsFreeListeningSettings {
  static let enabledDefaultsKey = DefaultsKey.handsFreeListeningEnabled.rawValue
  static let pausedDefaultsKey = DefaultsKey.handsFreeListeningPaused.rawValue

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: enabledDefaultsKey)
  }

  static var isPaused: Bool {
    UserDefaults.standard.bool(forKey: pausedDefaultsKey)
  }

  /// Turn hands-free on: pin the DJI receiver when one is connected and no mic is chosen yet, then
  /// set Always Respond and Always On. The recording-mode observer in `AppState` starts the session.
  static func enable(availableDevices: [AudioCaptureService.InputDevice]) {
    let defaults = UserDefaults.standard
    let preferredUID = defaults.string(forKey: AudioCaptureService.preferredInputUIDDefaultsKey) ?? ""
    if preferredUID.isEmpty, let receiver = HandsFreeListening.djiReceiver(in: availableDevices) {
      defaults.set(receiver.uid, forKey: AudioCaptureService.preferredInputUIDDefaultsKey)
      log("Hands-free: pinned \(receiver.name) as the microphone")
    }
    defaults.set(true, forKey: enabledDefaultsKey)
    defaults.set(false, forKey: pausedDefaultsKey)
    applyListening(on: true)
    log("Hands-free: on")
  }

  /// Turn hands-free off. Always Respond goes off with it and recording returns to Off, so the
  /// switch means what it says: nothing keeps listening or answering behind it. The chosen
  /// microphone stays chosen.
  static func disable() {
    let defaults = UserDefaults.standard
    defaults.set(false, forKey: enabledDefaultsKey)
    defaults.set(false, forKey: pausedDefaultsKey)
    applyListening(on: false)
    log("Hands-free: off")
  }

  static func pause() {
    guard isEnabled, !isPaused else { return }
    UserDefaults.standard.set(true, forKey: pausedDefaultsKey)
    if AssistantSettings.shared.audioRecordingMode != .off {
      AssistantSettings.shared.audioRecordingMode = .off
    }
    NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
    log("Hands-free: paused")
  }

  static func resume() {
    guard isEnabled, isPaused else { return }
    UserDefaults.standard.set(false, forKey: pausedDefaultsKey)
    applyListening(on: true)
    log("Hands-free: resumed")
  }

  /// Called once at launch: a hands-free session that was listening when the app quit comes back
  /// listening, and one that was paused stays paused. Writes only when something disagrees, so an
  /// ordinary launch posts no spurious mode-change notifications.
  static func reconcileAtLaunch() {
    guard isEnabled, !isPaused else { return }
    applyListening(on: true)
  }

  private static func applyListening(on: Bool) {
    let settings = AssistantSettings.shared
    if settings.alwaysRespondEnabled != on {
      settings.alwaysRespondEnabled = on
    }
    let wanted: AssistantSettings.AudioRecordingMode = on ? .always : .off
    if settings.audioRecordingMode != wanted {
      settings.audioRecordingMode = wanted
    } else {
      // The mode did not move, but the switch did — views bound to the switch must still refresh.
      NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
    }
  }
}
