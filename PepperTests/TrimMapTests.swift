import CoreMedia
import Testing
@testable import Pepper

/// Render ranges on the composition's 1/600 s grid (`snappedForRendering`).
struct TrimMapTests {
    /// 287.916… s: the recording whose nanosecond In point made the
    /// reader reject the video composition (AVError -11841, fixed in 1.2.1).
    let duration = CMTime(value: 172_750, timescale: 600)

    private func seconds(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    @Test func nanosecondInPointEndsExactlyAtTheLastFrame() {
        let inPoint = CMTime(value: 2_718_647_083, timescale: 1_000_000_000)
        let map = TrimMap(outerTrim: CMTimeRange(start: inPoint, end: duration))
            .snappedForRendering(within: duration)
        #expect(map.outerTrim.start.timescale == 600)
        #expect(CMTimeCompare(map.outerTrim.end, duration) == 0)
    }

    @Test func nanosecondCutsLandOnTheGridInsideTheTrim() {
        let cut = CMTimeRange(start: CMTime(value: 100_123_456_789, timescale: 1_000_000_000),
                              end: CMTime(value: 110_987_654_321, timescale: 1_000_000_000))
        let map = TrimMap(outerTrim: CMTimeRange(start: .zero, duration: duration), cuts: [cut])
            .snappedForRendering(within: duration)
        #expect(map.cuts.count == 1)
        #expect(map.cuts[0].start.timescale == 600)
        #expect(map.keptRanges.count == 2)
        let kept = map.keptRanges.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
        #expect(CMTimeCompare(kept, map.outputDuration) == 0)
    }

    @Test func aTrimPastTheEndIsPulledBack() {
        let map = TrimMap(outerTrim: CMTimeRange(start: .zero, end: CMTimeAdd(duration, seconds(1))))
            .snappedForRendering(within: duration)
        #expect(CMTimeCompare(map.outerTrim.end, duration) == 0)
    }

    @Test func keptRangesSkipTheCuts() {
        let map = TrimMap(outerTrim: CMTimeRange(start: .zero, duration: seconds(10)),
                          cuts: [CMTimeRange(start: seconds(2), duration: seconds(1))])
        #expect(map.keptRanges.count == 2)
        #expect(CMTimeCompare(map.outputDuration, seconds(9)) == 0)
    }

    @Test func overlappingCutsMerge() {
        let map = TrimMap(outerTrim: CMTimeRange(start: .zero, duration: seconds(10)),
                          cuts: [CMTimeRange(start: seconds(2), duration: seconds(2)),
                                 CMTimeRange(start: seconds(3), duration: seconds(2))])
        #expect(map.cuts.count == 1)
        #expect(CMTimeCompare(map.cuts[0].end, seconds(5)) == 0)
    }
}
