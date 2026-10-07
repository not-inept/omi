import SwiftUI

/// Shared Capture/Listening control logic used by both the top bar's wordless status cluster
/// (`ShellStatusIcons`) and the legacy Home's column-aligned header
/// (`DashboardPage.homeHeader`). The two surfaces render different layouts but
/// drive identical behavior, so the toggle actions and status derivations live
/// here once. Each view keeps its own `@State`/`@AppStorage` (preserving SwiftUI
/// ownership + reactivity) and passes them in as values/bindings.
@MainActor
enum CaptureListeningLogic {
  // MARK: Status derivations

  static func captureStatus(appState: AppState, isCaptureMonitoring: Bool) -> HomeStatusState {
    if appState.isScreenCaptureKitBroken || appState.isScreenRecordingStale || !appState.hasScreenRecordingPermission {
      return .blocked
    }
    return isCaptureLive(isCaptureMonitoring: isCaptureMonitoring) ? .active : .inactive
  }

  static func isCaptureLive(isCaptureMonitoring: Bool) -> Bool {
    isCaptureMonitoring || ProactiveAssistantsPlugin.shared.isMonitoring
  }

  /// The top-bar / Home listening readout. A session that is only *armed* (Only Meetings, no
  /// call) is inactive — the mic is paused, so lighting the green dot would lie.
  static func listeningStatus(appState: AppState) -> HomeStatusState {
    if appState.transcriptionServiceError != nil { return .blocked }
    return appState.isLiveCapturing ? .active : .inactive
  }

  static func audioRecordingMode(raw: String) -> AssistantSettings.AudioRecordingMode {
    AssistantSettings.AudioRecordingMode(rawValue: raw) ?? .onlyMeetings
  }

  static func listeningModeTitle(appState: AppState, raw: String) -> String {
    // Hands-free owns the readout while it is on: the mode underneath is an implementation
    // detail, and "Always On" would hide the one state the user needs to see — paused.
    if HandsFreeListeningSettings.isEnabled {
      return HandsFreeListening.barTitle(for: handsFreeState(appState: appState))
    }
    // Surface the explicitly-chosen mic as the visible capture source. Meta
    // glasses advertise a Bluetooth codename (e.g. "EL AI 000F"), so product-
    // name matching alone can't identify them — an explicit user selection is
    // the reliable signal, and showing its real name stays honest either way.
    // While "Only during meetings" is armed but no meeting is live, no mic is
    // actually open — keep the mode title instead of implying live capture.
    if appState.isTranscribing, !appState.isAwaitingMeeting,
      let name = appState.recordingInputDeviceName
    {
      if AudioCaptureService.isMetaGlassesName(name) {
        return name.localizedCaseInsensitiveContains("oakley") ? name : "Ray-Ban Meta"
      }
      let preferredUID =
        UserDefaults.standard.string(
          forKey: AudioCaptureService.preferredInputUIDDefaultsKey) ?? ""
      if !preferredUID.isEmpty {
        return name
      }
    }
    switch audioRecordingMode(raw: raw) {
    case .off:
      return "Off"
    case .always:
      return "Always On"
    case .onlyMeetings:
      return appState.isAwaitingMeeting ? "Only Meetings" : "In Meeting"
    }
  }

  /// The hands-free state as far as the synchronous surfaces (top bar, Home) can know it. The
  /// "chosen mic missing" case needs a device enumeration, which only the Settings card does;
  /// here it is `nil`, so that card is where a missing receiver is reported.
  static func handsFreeState(appState: AppState) -> HandsFreeListening.State {
    HandsFreeListening.state(
      enabled: HandsFreeListeningSettings.isEnabled,
      paused: HandsFreeListeningSettings.isPaused,
      hasMicrophonePermission: appState.hasMicrophonePermission,
      isTranscribing: appState.isTranscribing,
      preferredUID: UserDefaults.standard.string(
        forKey: AudioCaptureService.preferredInputUIDDefaultsKey) ?? "",
      preferredDeviceIsPresent: nil,
      recordingInputDeviceName: appState.recordingInputDeviceName)
  }

  /// What one click on the listening control selects next, named for the tooltip.
  static func nextClickTitle(mode: AssistantSettings.AudioRecordingMode) -> String {
    if HandsFreeListeningSettings.isEnabled {
      return HandsFreeListening.barClickTitle(paused: HandsFreeListeningSettings.isPaused)
    }
    return audioRecordingModeTitle(nextAudioRecordingMode(after: mode))
  }

  /// Off → Always On → Only Meetings → Off.
  ///
  /// `AudioRecordingMode` has three cases, but the control only ever reached two of them: it
  /// flipped between `.off` and `.onlyMeetings`, so `.always` — the mode that actually records
  /// continuously — could not be selected from the top bar or Home at all, and turning the
  /// microphone "on" silently armed a gate that keeps it shut until a call starts.
  static func nextAudioRecordingMode(after mode: AssistantSettings.AudioRecordingMode)
    -> AssistantSettings.AudioRecordingMode
  {
    switch mode {
    case .off: return .always
    case .always: return .onlyMeetings
    case .onlyMeetings: return .off
    }
  }

  /// The name of a *mode*, for naming a state the session is not in yet.
  ///
  /// Distinct from `listeningModeTitle`, which describes the **running** session and may answer
  /// with the live microphone's own name ("Ray-Ban Meta") or with "In Meeting". That is the right
  /// answer for "what is happening now" and the wrong one for "what does this click select".
  static func audioRecordingModeTitle(_ mode: AssistantSettings.AudioRecordingMode) -> String {
    switch mode {
    case .off: return "Off"
    case .always: return "Always On"
    case .onlyMeetings: return "Only Meetings"
    }
  }

  // MARK: Actions

  /// Pause when listening, resume when paused. Resuming needs the microphone grant; a click spent
  /// on the permission prompt returns `nil` like the ordinary cycle does.
  @discardableResult
  static func pauseOrResumeHandsFree(appState: AppState, audioRecordingModeRaw: Binding<String>)
    -> AssistantSettings.AudioRecordingMode?
  {
    if HandsFreeListeningSettings.isPaused {
      guard appState.hasMicrophonePermission else {
        appState.requestMicrophonePermission()
        return nil
      }
      HandsFreeListeningSettings.resume()
    } else {
      HandsFreeListeningSettings.pause()
    }
    let landed = AssistantSettings.shared.audioRecordingMode
    audioRecordingModeRaw.wrappedValue = landed.rawValue
    AnalyticsManager.shared.settingToggled(
      setting: "hands_free_listening_paused", enabled: HandsFreeListeningSettings.isPaused)
    return landed
  }

  /// Advance the control one step. Returns the mode it landed on so a caller can react to the
  /// transition itself, or `nil` when the click was spent on the permission prompt and the state
  /// did not move.
  @discardableResult
  static func cycleListening(
    appState: AppState, audioRecordingModeRaw: Binding<String>, isTogglingListening: Binding<Bool>
  ) -> AssistantSettings.AudioRecordingMode? {
    // While hands-free is on, the control is its one-click Pause/Resume. Cycling the recording
    // policy underneath it would silently break the switch's promise.
    if HandsFreeListeningSettings.isEnabled {
      return pauseOrResumeHandsFree(appState: appState, audioRecordingModeRaw: audioRecordingModeRaw)
    }
    let currentMode = audioRecordingMode(raw: audioRecordingModeRaw.wrappedValue)
    let nextMode = nextAudioRecordingMode(after: currentMode)
    let enabled = nextMode != .off
    if enabled && !appState.hasMicrophonePermission {
      appState.requestMicrophonePermission()
      return nil
    }

    isTogglingListening.wrappedValue = true
    audioRecordingModeRaw.wrappedValue = nextMode.rawValue
    AssistantSettings.shared.audioRecordingMode = nextMode
    AnalyticsManager.shared.settingToggled(setting: "audio_recording_mode_\(nextMode.rawValue)", enabled: enabled)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      isTogglingListening.wrappedValue = false
    }
    return nextMode
  }

  static func toggleCapture(
    appState: AppState, screenAnalysisEnabled: Binding<Bool>, isCaptureMonitoring: Binding<Bool>,
    isTogglingCapture: Binding<Bool>
  ) {
    syncCaptureState(screenAnalysisEnabled: screenAnalysisEnabled, isCaptureMonitoring: isCaptureMonitoring)
    let enabled = !isCaptureLive(isCaptureMonitoring: isCaptureMonitoring.wrappedValue)
    isTogglingCapture.wrappedValue = true

    if enabled {
      ProactiveAssistantsPlugin.shared.refreshScreenRecordingPermission()
      guard ProactiveAssistantsPlugin.shared.hasScreenRecordingPermission else {
        screenAnalysisEnabled.wrappedValue = false
        isCaptureMonitoring.wrappedValue = false
        isTogglingCapture.wrappedValue = false
        ScreenCaptureService.requestScreenRecordingAccessAndOpenSettings()
        return
      }
    }

    screenAnalysisEnabled.wrappedValue = enabled
    AssistantSettings.shared.screenAnalysisEnabled = enabled
    AnalyticsManager.shared.settingToggled(setting: "monitoring", enabled: enabled)

    if enabled {
      ProactiveAssistantsPlugin.shared.startMonitoring { success, _ in
        DispatchQueue.main.async {
          isTogglingCapture.wrappedValue = false
          isCaptureMonitoring.wrappedValue = ProactiveAssistantsPlugin.shared.isMonitoring
          if !success {
            screenAnalysisEnabled.wrappedValue = false
            AssistantSettings.shared.screenAnalysisEnabled = false
            isCaptureMonitoring.wrappedValue = false
          }
        }
      }
    } else {
      ProactiveAssistantsPlugin.shared.stopMonitoring()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        isTogglingCapture.wrappedValue = false
        isCaptureMonitoring.wrappedValue = false
      }
    }
  }

  static func syncCaptureState(screenAnalysisEnabled: Binding<Bool>, isCaptureMonitoring: Binding<Bool>) {
    ProactiveAssistantsPlugin.shared.refreshScreenRecordingPermission()
    screenAnalysisEnabled.wrappedValue = AssistantSettings.shared.screenAnalysisEnabled
    isCaptureMonitoring.wrappedValue = ProactiveAssistantsPlugin.shared.isMonitoring
  }
}
