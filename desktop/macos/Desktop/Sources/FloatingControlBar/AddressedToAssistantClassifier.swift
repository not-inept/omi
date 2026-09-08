import Foundation

/// Decides whether a finalized ambient transcript segment reads as a question or request
/// addressed to the assistant, for the "Always Respond" continuous-listening feature
/// (Settings → General → Audio Recording).
///
/// This makes the same call a person skimming a transcript would, using only signals
/// available from text alone — there is no tone-of-voice or wake-word audio detector in
/// this codebase to lean on (checked: no "wake word" / "hey omi" match anywhere under
/// `Sources`). Three text-only signals:
///
///   1. It ends with a question mark.
///   2. It opens by addressing the assistant by name — "Omi, ...", "Hey Omi ...",
///      "OK Omi ...". This is a literal prefix match, not audio wake-word detection.
///   3. It opens with a bare imperative aimed at an assistant — "remind me to…",
///      "set a timer for…", "play some music", "what's on my calendar" (which also
///      satisfies rule 1, but many imperatives never end in "?").
///
/// Deliberately conservative: ordinary ambient conversation ("we should ship on
/// Friday.") matches none of these and is left alone.
enum AddressedToAssistantClassifier {
  /// Names the assistant answers to when addressed directly.
  static let addressNames: Set<String> = ["omi"]

  /// Greeting words that may precede an address name ("hey", "ok/okay Omi").
  static let addressGreetings: Set<String> = ["hey", "ok", "okay", "yo"]

  /// First words of a sentence that read as a command directed at an assistant,
  /// independent of punctuation.
  static let imperativeOpeners: Set<String> = [
    "what", "who", "when", "where", "why", "how",
    "can", "could", "would", "will",
    "please",
    "tell", "show", "remind", "give", "help",
    "find", "search", "define", "translate", "calculate",
    "set", "add", "start", "stop", "pause", "resume", "play", "open", "close", "turn",
  ]

  /// - Parameter text: a finalized transcript segment's text.
  /// - Returns: `true` when the segment reads as addressed to the assistant.
  static func isAddressedToAssistant(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if endsAsQuestion(trimmed) { return true }

    let words = normalizedWords(trimmed)
    guard let first = words.first else { return false }

    if addressNames.contains(first) { return true }
    if addressGreetings.contains(first), words.count > 1, addressNames.contains(words[1]) {
      return true
    }

    return imperativeOpeners.contains(first)
  }

  /// Trailing punctuation/whitespace-tolerant "?" check — a transcript can end with
  /// "...right now?" or "...right now? " or even "...right now?)" from ASR quirks.
  private static func endsAsQuestion(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last else { return false }
    if last == "?" { return true }
    // Allow one trailing closing-punctuation character after the "?" (ASR/quoting artifact).
    if trimmed.count > 1, ")\"'".contains(last) {
      let withoutLast = trimmed.dropLast()
      return withoutLast.last == "?"
    }
    return false
  }

  /// Lowercased, letter/number-only tokens — strips punctuation so "Omi," and "Omi"
  /// match the same way, without touching the original text used for the query.
  private static func normalizedWords(_ text: String) -> [String] {
    text
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }
}
