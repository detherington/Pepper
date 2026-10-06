import Foundation
import Testing
@testable import Pepper

/// The Export sheet's "About 2 min left" (`ExportTimeLeft`).
struct ExportTimeLeftTests {
    @Test func waitsUntilThereIsEnoughToGoOn() {
        #expect(ExportTimeLeft.text(progress: 0.02, elapsed: 5) == nil)
        #expect(ExportTimeLeft.text(progress: 0.5, elapsed: 1) == nil)
        #expect(ExportTimeLeft.text(progress: 1, elapsed: 30) == nil)
    }

    @Test func roundsToWholeMinutesThenFiveSeconds() {
        // Half done in a minute: a minute to go.
        #expect(ExportTimeLeft.text(progress: 0.5, elapsed: 60) == "About 1 min left")
        // A tenth done in 30 s: 4.5 min to go, said as 5.
        #expect(ExportTimeLeft.text(progress: 0.1, elapsed: 30) == "About 5 min left")
        // Three quarters done in 60 s: 20 s to go.
        #expect(ExportTimeLeft.text(progress: 0.75, elapsed: 60) == "About 20 s left")
        // 58 s left reads as a minute, not "60 s".
        #expect(ExportTimeLeft.text(progress: 0.5, elapsed: 58) == "About 1 min left")
    }

    @Test func theLastFewSecondsAreAlmostDone() {
        #expect(ExportTimeLeft.text(progress: 0.9, elapsed: 45) == "Almost done")
    }
}
