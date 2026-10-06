import CoreMedia
import Testing
@testable import Pepper

/// Pause cutting leaves in what happens around clicks and key presses
/// (`SilenceAnalyzer.sparing` / `widening`): in a walkthrough a quiet
/// stretch with clicks is the demo.
struct SilenceAnalyzerTests {
    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    private func spans(_ ranges: [CMTimeRange]) -> [[Double]] {
        ranges.map { [CMTimeGetSeconds($0.start), CMTimeGetSeconds($0.end)] }
    }

    @Test func aClickSplitsTheSilenceAroundIt() {
        // 1 s before the click and 3 s after it stay in.
        let pieces = SilenceAnalyzer.sparing([range(10, 20)], activity: [14])
        #expect(spans(pieces) == [[10, 13], [17, 20]])
    }

    @Test func leftoversTooShortToCutAreDropped() {
        let pieces = SilenceAnalyzer.sparing([range(10, 12)], activity: [11.2])
        #expect(pieces.isEmpty)
    }

    @Test func withoutActivityTheSilencesStand() {
        let silences = [range(1, 2), range(5, 9)]
        #expect(spans(SilenceAnalyzer.sparing(silences, activity: [])) == spans(silences))
    }

    @Test func wideningKeepsTheFirstAndLastClick() {
        let kept = SilenceAnalyzer.widening(range(5, 50), toKeep: [2, 52], duration: CMTime(seconds: 60, preferredTimescale: 600))
        #expect(spans([kept]) == [[1, 55]])
    }

    @Test func wideningStaysInsideTheRecording() {
        let kept = SilenceAnalyzer.widening(range(0.5, 59), toKeep: [0.2, 59.5], duration: CMTime(seconds: 60, preferredTimescale: 600))
        #expect(spans([kept]) == [[0, 60]])
    }
}
