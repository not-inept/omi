import Foundation

/// Pure gate for whether a just-arrived ambient backend segment is even a candidate for
/// "Always Respond" — before the debounce/settle window and the text classifier run.
///
/// Kept separate from `AddressedToAssistantClassifier` (which only judges the text) so
/// every non-text precondition — the toggle, the listening mode, who's speaking, and the
/// echo guard — lives in one reviewable place.
enum AlwaysRespondGate {
  /// - Parameters:
  ///   - isUser: `segment.is_user` from the backend — never react to someone else's
  ///     speech in a meeting; only the account holder's own voice can address Omi.
  ///   - text: the segment's current text.
  ///   - alwaysRespondEnabled: the Settings → General toggle.
  ///   - audioRecordingModeIsAlways: continuous ("Always On") listening must be the
  ///     active policy — Always Respond has no meaning under Off or Only Meetings.
  ///   - isAssistantSpeaking: `FloatingBarVoicePlaybackService.shared.isSpeaking` — the
  ///     echo guard. The ambient transcriber can pick up Omi's own TTS output through
  ///     speakers/mic bleed; never treat that as a new question.
  static func admitsCandidate(
    isUser: Bool,
    text: String,
    alwaysRespondEnabled: Bool,
    audioRecordingModeIsAlways: Bool,
    isAssistantSpeaking: Bool
  ) -> Bool {
    guard alwaysRespondEnabled, audioRecordingModeIsAlways else { return false }
    guard isUser, !isAssistantSpeaking else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// Settles a stream of same-`id` segment corrections into a single "finalized" callback,
/// so one spoken question yields exactly one answer even though the ambient transcriber
/// upserts a segment's text repeatedly as it corrects itself (`AppState+ListenEvents`
/// upserts by `segment.id` — there is no `is_final` flag on `TranscriptionService
/// .BackendSegment` to key off instead).
///
/// The scheduler is injected so this is testable without real timers: a fake scheduler
/// can capture the closure and invoke it manually to simulate the quiet window elapsing.
@MainActor
final class AlwaysRespondSegmentDebouncer {
  private let quietWindow: TimeInterval
  private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> DispatchWorkItem
  private var pending: [String: DispatchWorkItem] = [:]
  private var settledSegmentIDs: Set<String> = []

  /// - Parameters:
  ///   - quietWindow: how long a segment id's text must go unchanged before it is
  ///     treated as finalized. 1.2s is comfortably longer than the ASR's own
  ///     correction cadence for a short utterance without making a real question
  ///     feel laggy.
  ///   - schedule: real production default posts to the main queue after
  ///     `quietWindow`; tests substitute a synchronous fake that invokes the action
  ///     immediately (or on demand) to simulate the quiet window elapsing.
  init(
    quietWindow: TimeInterval = 1.2,
    schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> DispatchWorkItem = {
      delay, action in
      let item = DispatchWorkItem { MainActor.assumeIsolated(action) }
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
      return item
    }
  ) {
    self.quietWindow = quietWindow
    self.schedule = schedule
  }

  /// Call on every candidate user segment (already passed through `AlwaysRespondGate`).
  /// `onSettled` fires at most once per segment id, with whatever text was current when
  /// the quiet window elapsed without a further update to that same id.
  func segmentUpdated(id: String, text: String, onSettled: @escaping (String) -> Void) {
    guard !settledSegmentIDs.contains(id) else { return }
    pending[id]?.cancel()

    let item = schedule(quietWindow) { [weak self] in
      guard let self, !self.settledSegmentIDs.contains(id) else { return }
      self.settledSegmentIDs.insert(id)
      self.pending.removeValue(forKey: id)
      onSettled(text)
    }
    pending[id] = item
  }

  /// Clears all in-flight and remembered state — call when a transcription session
  /// ends/restarts so segment ids from a previous session can never suppress or
  /// spuriously fire a future one.
  func reset() {
    pending.values.forEach { $0.cancel() }
    pending.removeAll()
    settledSegmentIDs.removeAll()
  }
}
