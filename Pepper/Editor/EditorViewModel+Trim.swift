import SwiftUI
import AVFoundation
import AppKit

/// Trim and cuts: the outer trim, interior cuts, and automatic pause
/// cutting and trimming.
extension EditorViewModel {
    // MARK: - Trim controls

    /// Set the in-point. Clamped so there's at least 0.25s of trim duration.
    func setTrimStart(_ time: CMTime) {
        let minGap = CMTime(value: 250, timescale: 1000)
        let upperBound = CMTimeSubtract(trimEnd, minGap)
        let clamped = clamp(time, lower: .zero, upper: upperBound)
        guard clamped != trimStart else { return }
        let old = trimStart
        trimStart = clamped
        applyLayout()  // outputRange shifted — re-prime cards/fades
        // trimStart is a plain var (no `didSet`), so the keypath-based
        // helper can't rely on didSet to register the redo. Use the
        // snapshot form, which explicitly re-registers inside its undo
        // closure.
        registerUndoableSnapshot(
            "Change Trim In",
            coalesceKey: "trimStart",
            capture: { $0.trimStart },
            oldState: old
        ) { vm, state in
            vm.trimStart = state
            vm.applyLayout()
        }
    }

    /// Set the out-point. Clamped so there's at least 0.25s of trim duration.
    func setTrimEnd(_ time: CMTime) {
        let minGap = CMTime(value: 250, timescale: 1000)
        let lowerBound = CMTimeAdd(trimStart, minGap)
        let clamped = clamp(time, lower: lowerBound, upper: duration)
        guard clamped != trimEnd else { return }
        let old = trimEnd
        trimEnd = clamped
        applyLayout()
        registerUndoableSnapshot(
            "Change Trim Out",
            coalesceKey: "trimEnd",
            capture: { $0.trimEnd },
            oldState: old
        ) { vm, state in
            vm.trimEnd = state
            vm.applyLayout()
        }
    }

    func setTrimStartToCurrent() { setTrimStart(currentTime) }
    func setTrimEndToCurrent()   { setTrimEnd(currentTime) }

    func clearTrim() {
        let oldStart = trimStart
        let oldEnd = trimEnd
        trimStart = .zero
        trimEnd = duration
        applyLayout()
        registerUndoableSnapshot(
            "Reset Trim",
            capture: { vm in (vm.trimStart, vm.trimEnd) },
            oldState: (oldStart, oldEnd)
        ) { vm, state in
            vm.trimStart = state.0
            vm.trimEnd = state.1
            vm.applyLayout()
        }
    }

    // MARK: - Interior cuts (ripple delete)

    /// Smallest cut we're willing to place. Below this it's almost
    /// certainly a misclick, and it introduces jitter in the exported
    /// file without actually saving anything.
    private static let minCutDuration = CMTime(value: 100, timescale: 1000)  // 0.1s

    /// Excise `range` (in source-composition time) from the output.
    /// Ranges overlapping existing cuts are merged by `TrimMap`;
    /// ranges outside the outer trim are clamped / dropped. No-op if
    /// the clamped range is shorter than `minCutDuration`.
    func insertCut(_ range: CMTimeRange) {
        // Clamp to outer trim before the min-duration check so a cut
        // that extends past trimEnd still counts as long as the clipped
        // portion is long enough to be meaningful.
        let clampedStart = clamp(range.start, lower: trimStart, upper: trimEnd)
        let clampedEnd   = clamp(range.end,   lower: trimStart, upper: trimEnd)
        guard CMTimeCompare(clampedEnd, clampedStart) > 0 else { return }
        let clamped = CMTimeRange(start: clampedStart, end: clampedEnd)
        guard CMTimeCompare(clamped.duration, Self.minCutDuration) >= 0 else { return }
        let old = cutRanges
        // Round-trip through TrimMap to merge + sort with any existing.
        let merged = TrimMap(outerTrim: trimRange, cuts: old + [clamped]).cuts
        guard merged != old else { return }
        cutRanges = merged
        applyLayout()
        registerUndoableSnapshot(
            "Cut Section",
            capture: { $0.cutRanges },
            oldState: old
        ) { vm, state in
            vm.cutRanges = state
            vm.applyLayout()
        }
    }

    /// Remove the cut at `index` (no-op if out of range). Restores the
    /// source region to the output timeline.
    func removeCut(at index: Int) {
        guard cutRanges.indices.contains(index) else { return }
        let old = cutRanges
        var next = cutRanges
        next.remove(at: index)
        cutRanges = next
        applyLayout()
        registerUndoableSnapshot(
            "Restore Cut",
            capture: { $0.cutRanges },
            oldState: old
        ) { vm, state in
            vm.cutRanges = state
            vm.applyLayout()
        }
    }

    /// Anchor a range selection at the current playhead. Subsequent
    /// scrubbing extends the selection to that new playhead position.
    func markSelectionStart() {
        selectionStart = currentTime
        selectionEnd = nil
    }

    /// A selection with both ends fixed: Shift-dragging on the timeline.
    func selectRange(from start: CMTime, to end: CMTime) {
        selectionStart = start
        selectionEnd = end
    }

    /// A plain click or drag on the timeline drops a Shift-dragged
    /// selection, as clicking away does elsewhere. A Mark stays: moving
    /// the playhead is how its selection gets its other end.
    func clearDraggedSelection() {
        if selectionEnd != nil { clearSelection() }
    }

    /// Drop the in-progress selection without cutting.
    func clearSelection() {
        selectionStart = nil
        selectionEnd = nil
    }

    /// If a selection is active, convert it into a cut and clear the
    /// selection anchor. No-op if there's no active selection.
    func cutSelection() {
        guard let range = selectionRange else { return }
        insertCut(range)
        clearSelection()
    }

    /// Wipe all interior cuts (keeps outer trim intact).
    func clearCuts() {
        guard !cutRanges.isEmpty else { return }
        let old = cutRanges
        cutRanges = []
        applyLayout()
        registerUndoableSnapshot(
            "Clear Cuts",
            capture: { $0.cutRanges },
            oldState: old
        ) { vm, state in
            vm.cutRanges = state
            vm.applyLayout()
        }
    }

    /// Scan the mic track for interior silences ≥ ~0.8s and insert them
    /// all as a single undoable batch. Existing cuts are preserved —
    /// silences are merged into the existing list via `TrimMap`'s
    /// normaliser, so re-running is idempotent. Quiet stretches where
    /// the user clicks or types are kept: in a walkthrough that's the
    /// demo, and cutting it took the clicks (and their zooms) with it.
    func autoCutSilences() {
        guard !isAutoCutting else { return }
        isAutoCutting = true
        let audioURL = project.bundle.micAudioURL
        let dur = duration
        let outerTrim = trimRange
        let activity = activityTimes
        Task { [weak self] in
            let scan = await SilenceAnalyzer.scan(audioURL: audioURL, duration: dur)
            await MainActor.run {
                guard let self else { return }
                defer { self.isAutoCutting = false }
                guard let scan else {
                    self.lastAutoCutCount = 0
                    return
                }
                // Only consider silences strictly inside the user's
                // current outer trim — detections outside are either
                // already covered by the outer trim or irrelevant.
                let silences = scan.interiorSilences.filter { sil in
                    CMTimeCompare(sil.start, outerTrim.start) >= 0 &&
                    CMTimeCompare(sil.end,   outerTrim.end)   <= 0
                }
                let candidates = SilenceAnalyzer.sparing(silences, activity: activity)
                // Merge with existing cuts via the TrimMap normaliser
                // (sorts, clamps, merges overlaps). Skip the operation
                // if nothing new would be added.
                let existing = self.cutRanges
                let merged = TrimMap(outerTrim: outerTrim, cuts: existing + candidates).cuts
                guard merged != existing else {
                    self.lastAutoCutCount = 0
                    return
                }
                let old = existing
                self.cutRanges = merged
                self.applyLayout()
                self.lastAutoCutCount = merged.count - existing.count
                self.registerUndoableSnapshot(
                    "Auto-cut Silences",
                    capture: { $0.cutRanges },
                    oldState: old
                ) { vm, state in
                    vm.cutRanges = state
                    vm.applyLayout()
                }
                PepperDebug.log("AUTOCUT: inserted \(merged.count - existing.count) silence cuts (\(candidates.count) candidates, \(existing.count) pre-existing)")
            }
        }
    }

    /// Re-run silence detection on the mic track and apply the detected
    /// trim. Useful if the user hit "Reset" and now wants the auto-trim
    /// back, or just wants to re-compute after moving files around.
    func autoTrimSilence() {
        let audioURL = project.bundle.micAudioURL
        let dur = duration
        let activity = activityTimes
        Task { [weak self] in
            guard let speech = await SilenceAnalyzer.detectContentRange(
                audioURL: audioURL,
                duration: dur
            ) else { return }
            let detected = SilenceAnalyzer.widening(speech, toKeep: activity, duration: dur)
            await MainActor.run {
                guard let self else { return }
                let oldStart = self.trimStart
                let oldEnd = self.trimEnd
                self.trimStart = detected.start
                self.trimEnd   = detected.end
                self.applyLayout()
                self.registerUndoableSnapshot(
                    "Auto-Trim Silence",
                    capture: { vm in (vm.trimStart, vm.trimEnd) },
                    oldState: (oldStart, oldEnd)
                ) { vm, state in
                    vm.trimStart = state.0
                    vm.trimEnd = state.1
                    vm.applyLayout()
                }
            }
        }
    }
}
