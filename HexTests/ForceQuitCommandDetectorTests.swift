import XCTest

@testable import Hex

final class ForceQuitCommandDetectorTests: XCTestCase {
	func testMatchesLocalASRForceQuitPhrase() {
		XCTAssertTrue(ForceQuitCommandDetector.matches("Force quit Local ASR"))
		XCTAssertTrue(ForceQuitCommandDetector.matches("Force quit Local ASR now"))
	}

	func testOldHexPhraseDoesNotTriggerForkCommand() {
		XCTAssertFalse(ForceQuitCommandDetector.matches("Force quit Hex"))
	}

	func testCommandMustBeTheEntireTranscript() {
		XCTAssertFalse(ForceQuitCommandDetector.matches("Please force quit Local ASR now"))
	}
}
