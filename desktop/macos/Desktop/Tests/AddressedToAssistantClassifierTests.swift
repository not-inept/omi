import XCTest

@testable import Omi_Computer

final class AddressedToAssistantClassifierTests: XCTestCase {
  // MARK: - Question mark

  func testEndsWithQuestionMarkIsAddressed() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("What time is it?"))
  }

  func testTrailingWhitespaceAfterQuestionMarkStillCounts() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("What time is it?  "))
  }

  func testTrailingClosingPunctuationAfterQuestionMarkStillCounts() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("\"What time is it?\""))
  }

  func testMidSentenceQuestionMarkWithoutEndingOneIsNotAddressed() {
    XCTAssertFalse(
      AddressedToAssistantClassifier.isAddressedToAssistant("She asked \"why?\" and walked off."))
  }

  // MARK: - Address by name

  func testBareNameAddressIsAddressed() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("Omi, what's on my calendar today"))
  }

  func testHeyNamePrefixIsAddressed() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("Hey Omi, remind me to call mom"))
  }

  func testOkNamePrefixIsCaseInsensitive() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("OK OMI pause the music"))
  }

  func testNameMentionedMidSentenceIsNotAnAddress() {
    XCTAssertFalse(
      AddressedToAssistantClassifier.isAddressedToAssistant("I was telling Sam about Omi yesterday."))
  }

  func testGreetingWithoutTheNameIsNotAnAddress() {
    XCTAssertFalse(AddressedToAssistantClassifier.isAddressedToAssistant("Hey Sam, did you see that"))
  }

  // MARK: - Imperative openers

  func testImperativeOpenerIsAddressed() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("Remind me to call mom at 5"))
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("Set a timer for ten minutes"))
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("Play some music"))
  }

  func testImperativeOpenerIsCaseInsensitive() {
    XCTAssertTrue(AddressedToAssistantClassifier.isAddressedToAssistant("PLEASE turn off the lights"))
  }

  func testImperativeVerbLaterInSentenceIsNotAnAddress() {
    XCTAssertFalse(AddressedToAssistantClassifier.isAddressedToAssistant("I told him to play some music."))
  }

  // MARK: - Ordinary conversation is left alone

  func testOrdinaryStatementIsNotAddressed() {
    XCTAssertFalse(AddressedToAssistantClassifier.isAddressedToAssistant("We should ship this on Friday."))
  }

  func testEmptyOrWhitespaceTextIsNotAddressed() {
    XCTAssertFalse(AddressedToAssistantClassifier.isAddressedToAssistant(""))
    XCTAssertFalse(AddressedToAssistantClassifier.isAddressedToAssistant("   "))
  }

  func testPunctuationOnlyTextIsNotAddressed() {
    XCTAssertFalse(AddressedToAssistantClassifier.isAddressedToAssistant("..."))
  }
}
