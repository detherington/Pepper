import SwiftUI
import AVFoundation
import AppKit

/// Playback: the player's observers, skipping cut ranges, transport and
/// keyboard stepping.
extension EditorViewModel {
    func attachPlayerObservers() {
        // Periodic time observer — drives the scrubber + trim-end enforcement.
        // ~30 updates/sec is plenty for a timeline UI and is cheap.
        let interval = CMTime(value: 1, timescale: 30)
        //
        // Both observers are delivered on the main queue, which the API's
        // @Sendable closure type can't express; `assumeIsolated` says so
        // (and traps rather than racing if that ever stopped being true).
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time
                if self.isPlaying,
                   self.trimEnd.isValid,
                   CMTimeCompare(time, self.trimEnd) >= 0 {
                    // Stop at the trim-out point.
                    self.player.pause()
                    // Snap exactly to trimEnd so the UI reads cleanly.
                    self.player.seek(to: self.trimEnd, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                // Fallback for interior cuts: if the playhead slipped into
                // a cut (e.g. a system hiccup delayed the boundary observer
                // past the cut.start), jump out. The boundary observer below
                // fires first in the common case, so this rarely runs.
                if let cut = self.cutRanges.first(where: {
                    CMTimeCompare(time, $0.start) >= 0 && CMTimeCompare(time, $0.end) < 0
                }) {
                    self.player.seek(to: cut.end, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }

        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate > 0
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    /// Wire up per-cut boundary observers so playback skips past each
    /// interior cut in real-time. Called whenever `cutRanges` changes
    /// (via `applyLayout`). Each observer fires exactly when the
    /// playhead crosses a cut-start and immediately seeks to the
    /// cut-end. Without this the user would see cut content play back
    /// during preview even though it won't be in the exported file.
    func refreshCutBoundaryObservers() {
        for token in cutBoundaryTokens {
            player.removeTimeObserver(token)
        }
        cutBoundaryTokens.removeAll(keepingCapacity: true)
        for cut in cutRanges {
            let start = cut.start
            let end = cut.end
            let token = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: start)],
                queue: .main
            ) { [weak self] in
                // Main queue, as above.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Only seek forward — if the user is scrubbing backward
                    // past the cut, the seek clamp in `seek(to:)` has
                    // already handled it.
                    guard CMTimeCompare(self.player.currentTime(), end) < 0 else { return }
                    self.player.seek(to: end, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            cutBoundaryTokens.append(token)
        }
    }

    /// If `time` falls inside an interior cut, return the nearest kept
    /// boundary (snap to `cut.end` for forward motion; caller can still
    /// force backward via `preferBackward`). Otherwise return `time`
    /// unchanged. Used by `seek(to:)` + scrubber drags.
    private func snapOutOfCut(_ time: CMTime, preferBackward: Bool = false) -> CMTime {
        for cut in cutRanges {
            if CMTimeCompare(time, cut.start) > 0 && CMTimeCompare(time, cut.end) < 0 {
                return preferBackward ? cut.start : cut.end
            }
        }
        return time
    }

    // MARK: - Playback controls

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            // If we're at or past trimEnd, or before trimStart, jump to trimStart first.
            if CMTimeCompare(currentTime, trimEnd) >= 0 || CMTimeCompare(currentTime, trimStart) < 0 {
                player.seek(to: trimStart, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        }
    }

    /// Seek to an arbitrary composition time. Clamped to [0, duration]
    /// and snapped out of any interior cut so the user never parks the
    /// playhead inside a region that won't exist in the exported file.
    func seek(to time: CMTime) {
        let clamped = clamp(time, lower: .zero, upper: duration)
        let snapped = snapOutOfCut(clamped)
        player.seek(to: snapped, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Keyboard navigation

    /// One-frame step at 60fps — smallest resolution the compositor
    /// renders. Used by arrow-key nudges.
    func stepFrame(forward: Bool) {
        let frame = CMTime(value: 1, timescale: 60)
        seek(to: forward ? CMTimeAdd(currentTime, frame) : CMTimeSubtract(currentTime, frame))
    }

    /// Mid-sized jump (1 second). Used by shift-arrow.
    func stepSecond(forward: Bool) {
        let step = CMTime(value: 1, timescale: 1)
        seek(to: forward ? CMTimeAdd(currentTime, step) : CMTimeSubtract(currentTime, step))
    }

    /// Larger jump (5 seconds). Used by J / L.
    func stepFiveSeconds(forward: Bool) {
        let step = CMTime(value: 5, timescale: 1)
        seek(to: forward ? CMTimeAdd(currentTime, step) : CMTimeSubtract(currentTime, step))
    }

    /// K — pauses regardless of current state (spacebar toggles; K is
    /// the "definitely pause now" shortcut matching pro editor apps).
    func pausePlayback() {
        player.pause()
    }

    /// Force the AVPlayer to re-run the compositor. Seeking to the CURRENT
    /// time is a no-op (AVPlayer short-circuits), so we nudge by one time
    /// unit to invalidate the cached frame.
    func forceRedraw() {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let time = player.currentTime()
        guard time.isValid, !time.isIndefinite else { return }

        let nudge = CMTime(value: 1, timescale: 600)
        let forward = CMTimeAdd(time, nudge)
        let duration = item.duration

        let target: CMTime
        if duration.isValid, !duration.isIndefinite, CMTimeCompare(forward, duration) < 0 {
            target = forward
        } else if CMTimeCompare(time, nudge) > 0 {
            target = CMTimeSubtract(time, nudge)
        } else {
            target = time
        }
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
