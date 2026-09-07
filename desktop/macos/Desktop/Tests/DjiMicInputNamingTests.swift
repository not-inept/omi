import XCTest

@testable import Omi_Computer

/// A DJI receiver has no vendor API on macOS — DJI publishes no SDK for the Mic
/// line — so its Core Audio product name is the only thing that identifies it.
/// That makes the match itself the whole feature, and worth pinning: too loose
/// and an unrelated interface gets labelled as a DJI receiver, too tight and the
/// receiver the user just plugged in looks like any other anonymous USB device.
final class DjiMicInputNamingTests: XCTestCase {

  func testMatchesTheDjiMicReceiverNamesAcrossTheProductLine() {
    XCTAssertTrue(AudioCaptureService.isDjiMicName("DJI MIC 3 RX"))
    XCTAssertTrue(AudioCaptureService.isDjiMicName("DJI Mic 2"))
    XCTAssertTrue(AudioCaptureService.isDjiMicName("DJI Mic Mini"))
    XCTAssertTrue(AudioCaptureService.isDjiMicName("dji mic"))
  }

  func testDoesNotClaimUnrelatedInputs() {
    XCTAssertFalse(AudioCaptureService.isDjiMicName("MacBook Pro Microphone"))
    XCTAssertFalse(AudioCaptureService.isDjiMicName("Scarlett 2i2 USB"))
    // Another DJI product that is not a microphone.
    XCTAssertFalse(AudioCaptureService.isDjiMicName("DJI Osmo Action"))
    // "mic" without DJI is any of a hundred interfaces.
    XCTAssertFalse(AudioCaptureService.isDjiMicName("Studio Mic"))
    XCTAssertFalse(AudioCaptureService.isDjiMicName(""))
  }

  func testDoesNotCollideWithTheGlassesMatch() {
    // Both matches run on the same name in the picker; neither may claim the
    // other's hardware.
    XCTAssertFalse(AudioCaptureService.isDjiMicName("Ray-Ban Meta"))
    XCTAssertFalse(AudioCaptureService.isMetaGlassesName("DJI MIC 3 RX"))
  }
}
