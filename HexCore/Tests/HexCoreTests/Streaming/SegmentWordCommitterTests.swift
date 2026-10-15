import XCTest
@testable import HexCore

final class SegmentWordCommitterTests: XCTestCase {
	func testTypesFinishedWordsAndHoldsBackTheGrowingOne() {
		var committer = SegmentWordCommitter()
		var step = committer.partial("Das Diktier")
		XCTAssertEqual(step.committed, "Das ")
		XCTAssertEqual(step.pending, "Diktier")
		XCTAssertTrue(step.startsSegment)
		step = committer.partial("Das Diktiergerät, läuft")
		XCTAssertEqual(step.committed, "Diktiergerät, ")
		XCTAssertEqual(step.pending, "läuft")
		XCTAssertFalse(step.startsSegment)
		let final = committer.final("Das Diktiergerät, läuft.")
		XCTAssertEqual(final.committed, "läuft.")
		XCTAssertFalse(final.startsSegment)
	}

	func testNothingIsTypedTwiceAndTheNextSegmentStartsFresh() {
		var committer = SegmentWordCommitter()
		_ = committer.partial(" Hallo Welt")
		XCTAssertEqual(committer.partial(" Hallo Welt").committed, "")
		XCTAssertEqual(committer.final("Hallo Welt").committed, "Welt")
		let next = committer.partial("Zweiter Satz")
		XCTAssertEqual(next.committed, "Zweiter ")
		XCTAssertTrue(next.startsSegment)
	}

	func testSegmentFinalizedWithoutPartialIsTypedWhole() {
		var committer = SegmentWordCommitter()
		let final = committer.final(" Kurz.")
		XCTAssertEqual(final.committed, "Kurz.")
		XCTAssertTrue(final.startsSegment)
	}

	func testRevisedEarlierTextOnlyAddsWordsBeyondWhatWasTyped() {
		var committer = SegmentWordCommitter()
		_ = committer.partial("eins zwei drei")
		let revised = committer.partial("Eins zwei drei vier")
		XCTAssertEqual(revised.committed, "")
		XCTAssertEqual(revised.pending, "drei vier")
		XCTAssertEqual(committer.final("Eins zwei drei vier.").committed, "drei vier.")
	}
}
