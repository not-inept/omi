import XCTest

@testable import Omi_Computer

final class HandsFreeListeningTests: XCTestCase {
  private func state(
    enabled: Bool = true,
    paused: Bool = false,
    hasMicrophonePermission: Bool = true,
    isTranscribing: Bool = true,
    preferredUID: String = "dji-rx-uid",
    preferredDeviceIsPresent: Bool? = true,
    recordingInputDeviceName: String? = "DJI MIC 3 RX"
  ) -> HandsFreeListening.State {
    HandsFreeListening.state(
      enabled: enabled,
      paused: paused,
      hasMicrophonePermission: hasMicrophonePermission,
      isTranscribing: isTranscribing,
      preferredUID: preferredUID,
      preferredDeviceIsPresent: preferredDeviceIsPresent,
      recordingInputDeviceName: recordingInputDeviceName)
  }

  func testOffWhenTheSwitchIsOff() {
    XCTAssertEqual(state(enabled: false), .off)
    // Off wins over everything else — a paused-but-off switch is still just off.
    XCTAssertEqual(state(enabled: false, paused: true, preferredDeviceIsPresent: false), .off)
  }

  func testPausedWinsOverAMissingMicAndAMissingPermission() {
    XCTAssertEqual(state(paused: true, preferredDeviceIsPresent: false), .paused)
    XCTAssertEqual(state(paused: true, hasMicrophonePermission: false), .paused)
  }

  func testNeedsPermissionBeforeAnythingAboutDevices() {
    XCTAssertEqual(
      state(hasMicrophonePermission: false, preferredDeviceIsPresent: false),
      .needsMicrophonePermission)
  }

  func testListeningNamesTheOpenMicrophone() {
    XCTAssertEqual(state(), .listening(micName: "DJI MIC 3 RX"))
  }

  func testStartingWhileTheSessionIsNotOpenYet() {
    XCTAssertEqual(state(isTranscribing: false, recordingInputDeviceName: nil), .starting)
  }

  func testMissingReceiverNamesTheFallbackWhileCapturing() {
    XCTAssertEqual(
      state(preferredDeviceIsPresent: false, recordingInputDeviceName: "MacBook Pro Microphone"),
      .micMissing(fallbackName: "MacBook Pro Microphone"))
    XCTAssertEqual(
      state(isTranscribing: false, preferredDeviceIsPresent: false, recordingInputDeviceName: nil),
      .micMissing(fallbackName: nil))
  }

  func testNoChosenMicIsNeverReportedMissing() {
    XCTAssertEqual(
      state(preferredUID: "", preferredDeviceIsPresent: false, recordingInputDeviceName: "MacBook Pro Microphone"),
      .listening(micName: "MacBook Pro Microphone"))
  }

  func testAnUnfinishedEnumerationIsNotAMissingMic() {
    XCTAssertEqual(state(preferredDeviceIsPresent: nil), .listening(micName: "DJI MIC 3 RX"))
  }

  func testStatusLinesSayWhatIsHappening() {
    XCTAssertEqual(
      HandsFreeListening.statusLine(for: .listening(micName: "DJI MIC 3 RX")),
      "Listening on DJI MIC 3 RX and answering what it hears")
    XCTAssertEqual(
      HandsFreeListening.statusLine(for: .paused), "Paused — not listening. Resume to continue")
    XCTAssertEqual(
      HandsFreeListening.statusLine(for: .micMissing(fallbackName: "MacBook Pro Microphone")),
      "Chosen microphone not connected — listening on MacBook Pro Microphone until it comes back")
    XCTAssertEqual(
      HandsFreeListening.statusLine(for: .micMissing(fallbackName: nil)),
      "Chosen microphone not connected — plug in the receiver")
  }

  func testBarTitleAndClickName() {
    XCTAssertEqual(HandsFreeListening.barTitle(for: .paused), "Hands-free paused")
    XCTAssertEqual(
      HandsFreeListening.barTitle(for: .listening(micName: "DJI MIC 3 RX")), "Hands-free · DJI MIC 3 RX")
    XCTAssertEqual(HandsFreeListening.barTitle(for: .micMissing(fallbackName: nil)), "Hands-free · mic missing")
    XCTAssertEqual(HandsFreeListening.barClickTitle(paused: false), "Pause hands-free")
    XCTAssertEqual(HandsFreeListening.barClickTitle(paused: true), "Resume hands-free")
  }

  func testPicksTheDjiReceiverByNameOnly() {
    let devices = [
      AudioCaptureService.InputDevice(id: 1, uid: "mac", name: "MacBook Pro Microphone"),
      AudioCaptureService.InputDevice(id: 2, uid: "rx", name: "DJI MIC 3 RX"),
      AudioCaptureService.InputDevice(id: 3, uid: "bh", name: "BlackHole 2ch"),
    ]
    XCTAssertEqual(HandsFreeListening.djiReceiver(in: devices)?.uid, "rx")
    XCTAssertNil(HandsFreeListening.djiReceiver(in: Array(devices[0...0])))
  }
}
