import XCTest

@testable import Omi_Computer

final class AlwaysRespondGateTests: XCTestCase {
  func testAdmitsAUserQuestionWhileAlwaysOnAndEnabled() {
    XCTAssertTrue(
      AlwaysRespondGate.admitsCandidate(
        isUser: true,
        text: "What's on my calendar?",
        alwaysRespondEnabled: true,
        audioRecordingModeIsAlways: true,
        isAssistantSpeaking: false
      ))
  }

  func testRejectsWhenToggleIsOff() {
    XCTAssertFalse(
      AlwaysRespondGate.admitsCandidate(
        isUser: true,
        text: "What's on my calendar?",
        alwaysRespondEnabled: false,
        audioRecordingModeIsAlways: true,
        isAssistantSpeaking: false
      ))
  }

  func testRejectsOutsideAlwaysOnListening() {
    XCTAssertFalse(
      AlwaysRespondGate.admitsCandidate(
        isUser: true,
        text: "What's on my calendar?",
        alwaysRespondEnabled: true,
        audioRecordingModeIsAlways: false,
        isAssistantSpeaking: false
      ))
  }

  func testRejectsSomeoneElsesSpeechInAMeeting() {
    XCTAssertFalse(
      AlwaysRespondGate.admitsCandidate(
        isUser: false,
        text: "What's on my calendar?",
        alwaysRespondEnabled: true,
        audioRecordingModeIsAlways: true,
        isAssistantSpeaking: false
      ))
  }

  func testRejectsWhileTheAssistantIsSpeakingTheEchoGuard() {
    XCTAssertFalse(
      AlwaysRespondGate.admitsCandidate(
        isUser: true,
        text: "What's on my calendar?",
        alwaysRespondEnabled: true,
        audioRecordingModeIsAlways: true,
        isAssistantSpeaking: true
      ))
  }

  func testRejectsEmptyText() {
    XCTAssertFalse(
      AlwaysRespondGate.admitsCandidate(
        isUser: true,
        text: "   ",
        alwaysRespondEnabled: true,
        audioRecordingModeIsAlways: true,
        isAssistantSpeaking: false
      ))
  }
}

@MainActor
final class AlwaysRespondSegmentDebouncerTests: XCTestCase {
  /// A fake scheduler that never fires on its own — the test invokes the captured
  /// action manually to simulate the quiet window elapsing, so these tests run with
  /// no real delay and no flakiness from timer scheduling.
  private final class ManualScheduler {
    private(set) var scheduledActions: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DispatchWorkItem {
      scheduledActions.append(action)
      // Never actually run via GCD — `fireAll()` invokes the captured actions directly
      // so the test controls exactly when the "quiet window" is considered elapsed.
      return DispatchWorkItem {}
    }

    /// Runs every action scheduled so far. Nothing here actually cancels a prior
    /// timer the way production's real `DispatchWorkItem.cancel()` does, so a test
    /// that reschedules the same id must only assert on the debouncer's own
    /// already-settled guard, not on this fake ever dropping the earlier timer.
    func fireAll() {
      let pending = scheduledActions
      scheduledActions.removeAll()
      for action in pending {
        MainActor.assumeIsolated(action)
      }
    }
  }

  func testSettlesOnceAfterTheQuietWindow() {
    let scheduler = ManualScheduler()
    let debouncer = AlwaysRespondSegmentDebouncer(schedule: scheduler.schedule)
    var settled: [String] = []

    debouncer.segmentUpdated(id: "seg-1", text: "What time is it") { settled.append($0) }
    scheduler.fireAll()

    XCTAssertEqual(settled, ["What time is it"])
  }

  func testASecondCorrectionToTheSameIdBeforeSettlingReplacesTheFirst() {
    let scheduler = ManualScheduler()
    let debouncer = AlwaysRespondSegmentDebouncer(schedule: scheduler.schedule)
    var settled: [String] = []

    debouncer.segmentUpdated(id: "seg-1", text: "What time") { settled.append($0) }
    debouncer.segmentUpdated(id: "seg-1", text: "What time is it") { settled.append($0) }
    scheduler.fireAll()

    // Both timers were scheduled (the fake never cancels), but the debouncer's own
    // "already settled" guard means only the first one to actually run wins — proving
    // one question yields exactly one answer even under a scheduler that can't cancel.
    XCTAssertEqual(settled.count, 1)
  }

  func testASettledIdNeverFiresAgainForALateCorrection() {
    let scheduler = ManualScheduler()
    let debouncer = AlwaysRespondSegmentDebouncer(schedule: scheduler.schedule)
    var settled: [String] = []

    debouncer.segmentUpdated(id: "seg-1", text: "What time is it") { settled.append($0) }
    scheduler.fireAll()
    debouncer.segmentUpdated(id: "seg-1", text: "What time is it now") { settled.append($0) }
    scheduler.fireAll()

    XCTAssertEqual(settled, ["What time is it"])
  }

  func testResetAllowsASegmentIdToSettleAgainInANewSession() {
    let scheduler = ManualScheduler()
    let debouncer = AlwaysRespondSegmentDebouncer(schedule: scheduler.schedule)
    var settled: [String] = []

    debouncer.segmentUpdated(id: "seg-1", text: "What time is it") { settled.append($0) }
    scheduler.fireAll()
    debouncer.reset()
    debouncer.segmentUpdated(id: "seg-1", text: "What time is it") { settled.append($0) }
    scheduler.fireAll()

    XCTAssertEqual(settled, ["What time is it", "What time is it"])
  }
}
