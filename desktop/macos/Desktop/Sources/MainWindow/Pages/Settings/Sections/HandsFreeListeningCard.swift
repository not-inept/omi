import OmiTheme
import SwiftUI

/// Settings → General: the hands-free switch, its status line and its Pause button. One card so
/// the three facts a person needs — is it on, is it listening right now, on which mic — sit
/// together instead of being inferred from Audio Recording, Always Respond and the mic picker.
///
/// The card enumerates input devices (the same Core Audio list the microphone picker shows) so
/// it can say "chosen microphone not connected" the moment the DJI receiver is unplugged, and
/// offer to pin the receiver in one click when it is plugged in but not chosen.
struct HandsFreeListeningCard: View {
  @ObservedObject var appState: AppState
  @AppStorage(HandsFreeListeningSettings.enabledDefaultsKey) private var enabled = false
  @AppStorage(HandsFreeListeningSettings.pausedDefaultsKey) private var paused = false
  @AppStorage(AudioCaptureService.preferredInputUIDDefaultsKey) private var preferredUID = ""
  @StateObject private var deviceListObserver = AudioInputDeviceListObserver()
  @State private var devices: [AudioCaptureService.InputDevice] = []
  @State private var hasEnumerated = false
  @State private var refreshInFlight = false
  @State private var refreshQueued = false

  var body: some View {
    VStack(alignment: .leading, spacing: OmiSpacing.md) {
      HStack(spacing: OmiSpacing.lg) {
        SettingsIconTile(symbol: "waveform.badge.mic")

        VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
          Text("Hands-free")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Text(HandsFreeListening.statusLine(for: state))
            .scaledFont(size: OmiType.body)
            .foregroundColor(needsAttention ? SettingsInk.notice : Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.handsfree.status")
        }

        Spacer()

        Toggle(
          "",
          isOn: Binding(
            get: { enabled },
            set: { newValue in
              if newValue {
                guard appState.hasMicrophonePermission else {
                  appState.requestMicrophonePermission()
                  return
                }
                HandsFreeListeningSettings.enable(availableDevices: devices)
              } else {
                HandsFreeListeningSettings.disable()
              }
              AnalyticsManager.shared.settingToggled(setting: "hands_free_listening", enabled: newValue)
            }
          )
        )
        .toggleStyle(OmiToggleStyle())
        .labelsHidden()
        .frame(width: 36, height: 20)
        .accessibilityIdentifier("settings.handsfree.toggle")
      }

      if enabled {
        HStack(spacing: OmiSpacing.md) {
          Button(paused ? "Resume" : "Pause") {
            if paused {
              HandsFreeListeningSettings.resume()
            } else {
              HandsFreeListeningSettings.pause()
            }
          }
          .buttonStyle(OmiButtonStyle(paused ? .primary : .secondary, size: .compact))
          .accessibilityIdentifier("settings.handsfree.pause")

          if let receiver = unpinnedReceiver {
            Button("Use \(receiver.name)") {
              preferredUID = receiver.uid
              Task { @MainActor in
                if await appState.prepareTranscriptionRestartAfterSettingsChange() {
                  appState.startTranscription()
                }
              }
            }
            .buttonStyle(OmiButtonStyle(.secondary, size: .compact))
            .accessibilityIdentifier("settings.handsfree.usereceiver")
          }

          Spacer()
        }
      }
    }
    .onAppear { deviceListObserver.start() }
    .onDisappear { deviceListObserver.stop() }
    .task(id: deviceListObserver.revision) { await refreshDevices() }
  }

  private var state: HandsFreeListening.State {
    HandsFreeListening.state(
      enabled: enabled,
      paused: paused,
      hasMicrophonePermission: appState.hasMicrophonePermission,
      isTranscribing: appState.isTranscribing,
      preferredUID: preferredUID,
      preferredDeviceIsPresent: hasEnumerated ? devices.contains { $0.uid == preferredUID } : nil,
      recordingInputDeviceName: appState.recordingInputDeviceName)
  }

  private var needsAttention: Bool {
    switch state {
    case .micMissing, .needsMicrophonePermission: return true
    default: return false
    }
  }

  /// A DJI receiver is plugged in but some other device (or the system default) is chosen.
  private var unpinnedReceiver: AudioCaptureService.InputDevice? {
    guard let receiver = HandsFreeListening.djiReceiver(in: devices) else { return nil }
    return receiver.uid == preferredUID ? nil : receiver
  }

  /// Same coalescing as `MicrophonePickerCard.refreshDevices`: a wedged HAL strands at most one
  /// probe, and a notification that lands mid-probe folds into one trailing rerun.
  @MainActor
  private func refreshDevices() async {
    if refreshInFlight {
      refreshQueued = true
      return
    }
    refreshInFlight = true
    defer { refreshInFlight = false }
    repeat {
      refreshQueued = false
      let latest = await Task.detached(priority: .utility) {
        AudioCaptureService.availableInputDevices()
      }.value
      devices = latest
      hasEnumerated = true
    } while refreshQueued
  }
}
