import SwiftUI
import AVFoundation
import AppKit

/// Zooms and full-screen moments (keyframe editing), and Quick polish.
extension EditorViewModel {
    // MARK: - Keyframe edits (talking head + zoom)

    /// Apply an edited keyframe list: preview, save, and register undo.
    /// With a `coalesceKey`, rapid repeats (a pill or slider drag)
    /// collapse into one undo step back to the pre-drag list. `seekTo`
    /// moves the playhead before the preview refreshes.
    private func commitKeyframes<K: RampKeyframe>(
        _ keyPath: ReferenceWritableKeyPath<EditorViewModel, [K]>,
        _ updated: [K],
        saving file: SidecarFile,
        actionName: String,
        coalesceKey: AnyHashable? = nil,
        seekTo: CMTime? = nil
    ) {
        let old = self[keyPath: keyPath]
        self[keyPath: keyPath] = updated
        if let seekTo { seek(to: seekTo) }
        applyLayout()
        scheduleSave(file)
        registerUndoableSnapshot(
            actionName,
            coalesceKey: coalesceKey,
            capture: { $0[keyPath: keyPath] },
            oldState: old
        ) { vm, state in
            vm[keyPath: keyPath] = state
            vm.applyLayout()
            vm.scheduleSave(file)
        }
    }

    // MARK: - Talking-head keyframes

    /// Default parameters for a new talking-head keyframe.
    static let defaultTalkingHeadHold = CMTime(seconds: 3.0, preferredTimescale: 600)
    static let talkingHeadInOut = CMTime(seconds: 0.5, preferredTimescale: 600)

    /// Where "Add at playhead" would put a talking-head moment: the first
    /// gap after the playhead that fits at least a minimum-hold keyframe,
    /// capped at the default length.
    private func nextTalkingHeadSlot() -> (start: CMTime, maxTotalDuration: CMTime)? {
        let ramps = CMTimeMultiply(Self.talkingHeadInOut, multiplier: 2)
        return RampKeyframes.nextSlot(
            in: talkingHeadKeyframes,
            from: currentTime,
            duration: duration,
            minTotal: CMTimeAdd(ramps, RampKeyframes.minHold),
            defaultTotal: CMTimeAdd(ramps, Self.defaultTalkingHeadHold)
        )
    }

    var canAddTalkingHeadAtPlayhead: Bool {
        nextTalkingHeadSlot() != nil
    }

    func addTalkingHeadAtPlayhead() {
        guard let slot = nextTalkingHeadSlot() else { return }
        let kf = TalkingHeadKeyframe(
            startTime: slot.start,
            inDuration: Self.talkingHeadInOut,
            holdEndTime: RampKeyframes.holdEnd(start: slot.start, total: slot.maxTotalDuration, inOut: Self.talkingHeadInOut),
            outDuration: Self.talkingHeadInOut
        )
        // Move the playhead to the new keyframe so the user gets a
        // preview and the "Add" button auto-advances again on next click.
        commitKeyframes(\.talkingHeadKeyframes, RampKeyframes.sorted(talkingHeadKeyframes + [kf]),
                        saving: .talkingHead, actionName: "Add Talking Head", seekTo: slot.start)
    }

    func removeTalkingHeadKeyframe(id: UUID) {
        commitKeyframes(\.talkingHeadKeyframes, talkingHeadKeyframes.filter { $0.id != id },
                        saving: .talkingHead, actionName: "Remove Talking Head")
    }

    /// Move a talking-head keyframe so it starts at `newStart`, keeping its
    /// length and staying clear of its neighbours.
    func moveTalkingHeadKeyframe(id: UUID, to newStart: CMTime) {
        guard let moved = RampKeyframes.moving(talkingHeadKeyframes, id: id, to: newStart, duration: duration) else { return }
        commitKeyframes(\.talkingHeadKeyframes, moved, saving: .talkingHead,
                        actionName: "Move Talking Head", coalesceKey: "thMove:\(id.uuidString)")
    }

    /// Change a keyframe's hold (start and ramps unchanged), clamped so it
    /// can't run into the next keyframe or past the end.
    func setTalkingHeadHold(id: UUID, hold: CMTime) {
        guard let updated = RampKeyframes.settingHold(talkingHeadKeyframes, id: id, hold: hold, duration: duration) else { return }
        commitKeyframes(\.talkingHeadKeyframes, updated, saving: .talkingHead,
                        actionName: "Change Talking-Head Hold", coalesceKey: "thHold:\(id.uuidString)")
    }

    /// Update a keyframe's target diameter fraction (0.2 … 0.95).
    func setTalkingHeadDiameterFraction(id: UUID, fraction: CGFloat) {
        guard let idx = talkingHeadKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0.2, min(0.95, fraction))
        guard clamped != talkingHeadKeyframes[idx].targetDiameterFraction else { return }
        var updated = talkingHeadKeyframes
        updated[idx].targetDiameterFraction = clamped
        commitKeyframes(\.talkingHeadKeyframes, updated, saving: .talkingHead,
                        actionName: "Change Talking-Head Size", coalesceKey: "thSize:\(id.uuidString)")
    }

    // MARK: - Zoom-keyframe editing

    /// Default timing for a manually added zoom — matches what the
    /// auto-generator uses so manual adds feel consistent alongside the
    /// auto ones. The peak scale comes from `zoomTuning`.
    static let defaultZoomInOut = CMTime(seconds: 0.5, preferredTimescale: 600)
    static let defaultZoomHold = CMTime(seconds: 1.5, preferredTimescale: 600)

    /// Zoom's equivalent of `nextTalkingHeadSlot`.
    private func nextZoomSlot() -> (start: CMTime, maxTotalDuration: CMTime)? {
        let ramps = CMTimeMultiply(Self.defaultZoomInOut, multiplier: 2)
        return RampKeyframes.nextSlot(
            in: zoomKeyframes,
            from: currentTime,
            duration: duration,
            minTotal: CMTimeAdd(ramps, RampKeyframes.minHold),
            defaultTotal: CMTimeAdd(ramps, Self.defaultZoomHold)
        )
    }

    var canAddZoomAtPlayhead: Bool {
        nextZoomSlot() != nil
    }

    /// Add a manual zoom keyframe at (or just after) the playhead,
    /// targeting the centre of the canvas; "Set focus" retargets it.
    func addZoomAtPlayhead() {
        guard let slot = nextZoomSlot() else { return }
        let kf = ZoomKeyframe(
            startTime: slot.start,
            inDuration: Self.defaultZoomInOut,
            holdEndTime: RampKeyframes.holdEnd(start: slot.start, total: slot.maxTotalDuration, inOut: Self.defaultZoomInOut),
            outDuration: Self.defaultZoomInOut,
            target: CGPoint(x: outputSize.width / 2, y: outputSize.height / 2),
            scale: zoomTuning.scale
        )
        commitKeyframes(\.zoomKeyframes, RampKeyframes.sorted(zoomKeyframes + [kf]),
                        saving: .zoom, actionName: "Add Zoom", seekTo: slot.start)
    }

    func removeZoomKeyframe(id: UUID) {
        if selectedZoomID == id { selectedZoomID = nil }
        commitKeyframes(\.zoomKeyframes, zoomKeyframes.filter { $0.id != id },
                        saving: .zoom, actionName: "Remove Zoom")
    }

    /// Inspector "How close": one peak scale for every zoom, and for
    /// zooms added or regenerated later. One undo step (per drag).
    func setScaleForAllZooms(_ scale: CGFloat) {
        let clamped = max(1.0, min(2.5, scale))
        var tuning = zoomTuning
        tuning.scale = clamped
        zoomTuning = tuning
        let updated = zoomKeyframes.map { kf -> ZoomKeyframe in
            var k = kf
            k.scale = clamped
            return k
        }
        guard updated != zoomKeyframes else { return }
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Closeness", coalesceKey: "zoomScaleAll")
    }

    /// Inspector "How long it stays zoomed". Shifts every zoom's hold by
    /// the change rather than setting one length: an auto zoom's hold
    /// spans its whole cluster of clicks plus this trailing time, so a
    /// flat value would cut long clusters short.
    func setHoldForAllZooms(_ seconds: TimeInterval) {
        let delta = seconds - zoomTuning.holdSeconds
        guard delta != 0 else { return }
        var tuning = zoomTuning
        tuning.holdSeconds = seconds
        zoomTuning = tuning
        var updated = zoomKeyframes
        for kf in zoomKeyframes {
            guard let current = updated.first(where: { $0.id == kf.id }) else { continue }
            let hold = CMTimeGetSeconds(CMTimeSubtract(current.holdEndTime, CMTimeAdd(current.startTime, current.inDuration)))
            let target = CMTime(seconds: hold + delta, preferredTimescale: 600)
            if let next = RampKeyframes.settingHold(updated, id: kf.id, hold: target, duration: duration) {
                updated = next
            }
        }
        guard updated != zoomKeyframes else { return }
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Length", coalesceKey: "zoomHoldAll")
    }

    /// Inspector: one size for every full-screen (talking-head) moment.
    func setSizeForAllTalkingHeads(_ fraction: CGFloat) {
        let clamped = max(0.2, min(0.95, fraction))
        let updated = talkingHeadKeyframes.map { kf -> TalkingHeadKeyframe in
            var k = kf
            k.targetDiameterFraction = clamped
            return k
        }
        guard updated != talkingHeadKeyframes else { return }
        commitKeyframes(\.talkingHeadKeyframes, updated, saving: .talkingHead,
                        actionName: "Change Full-Screen Size", coalesceKey: "thSizeAll")
    }

    /// One line of the Quick polish card's report.
    struct PolishStep: Equatable {
        enum Kind { case working, done, nothing, problem }
        var kind: Kind
        var text: String
    }

    /// What the last "Polish my video" did. Worded in the past tense so
    /// it stays true after later edits. Nil until it runs, or once the
    /// user closes it.
    struct PolishReport: Equatable {
        var zooms: PolishStep
        var captions: PolishStep
        var isWorking: Bool { zooms.kind == .working || captions.kind == .working }
    }

    /// True while "Polish my video" still has work running.
    var isPolishing: Bool { polishReport?.isWorking ?? false }

    /// Polish can't start while captions are already being written.
    var canPolish: Bool { !isTranscribing && !isLoading && loadError == nil }

    func dismissPolishReport() {
        polishReport = nil
    }

    /// Inspector "Polish my video": zooms on the clicks and captions,
    /// the two things most walkthroughs want. Cutting pauses is left to
    /// the Cuts row: it removes footage, which one button shouldn't do
    /// unasked. Each part is its own undo step, running it again keeps
    /// what's there, and the card reports what happened, including
    /// when there was nothing to do (a short clip with no clicks or
    /// speech used to look like a dead button).
    func quickPolish() {
        guard canPolish else { return }
        let zoomWasOn = zoomEnabled
        zoomEnabled = true
        let zooms: PolishStep
        if !zoomKeyframes.isEmpty {
            // Usually the case: zooms are made when the recording opens.
            zooms = zoomWasOn
                ? PolishStep(kind: .done, text: "\(Self.count(zoomKeyframes.count, "zoom")) already follow your clicks")
                : PolishStep(kind: .done, text: "Turned on \(Self.count(zoomKeyframes.count, "zoom")) on your clicks")
        } else if loggedClickCount == 0 {
            zooms = PolishStep(kind: .nothing, text: "No clicks to zoom into")
        } else {
            regenerateZoomFromClicks()
            zooms = zoomKeyframes.isEmpty
                ? PolishStep(kind: .nothing, text: "No clicks inside the recorded area")
                : PolishStep(kind: .done, text: "Added \(Self.count(zoomKeyframes.count, "zoom")) on your clicks")
        }

        let captionsWereOn = captionStyle.enabled
        if !captionsWereOn {
            var style = captionStyle
            style.enabled = true
            captionStyle = style
        }
        guard transcription == nil else {
            let text = captionsWereOn ? "Captions were already on" : "Turned your captions back on"
            polishReport = PolishReport(zooms: zooms, captions: PolishStep(kind: .done, text: text))
            return
        }
        polishReport = PolishReport(zooms: zooms, captions: PolishStep(kind: .working, text: "Writing captions…"))
        // The card says so beforehand when macOS will ask for Speech
        // Recognition, so the prompt isn't a surprise.
        generateCaptions { [weak self] result in
            guard let self else { return }
            let step: PolishStep
            switch result {
            case .success(let lines):
                step = PolishStep(kind: .done, text: "Wrote \(Self.count(lines, "caption line"))")
            case .failure(CaptionTranscriber.TranscriberError.noSpeechDetected):
                step = PolishStep(kind: .nothing, text: "No speech to caption")
            case .failure:
                step = PolishStep(kind: .problem, text: "Couldn't write captions")
                // The Captions row says why and what to do.
                self.openInspectorFeature = .captions
            }
            self.polishReport?.captions = step
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Move a zoom keyframe so it starts at `newStart`, keeping its length
    /// and staying clear of its neighbours. Called by the timeline pill.
    func moveZoomKeyframe(id: UUID, to newStart: CMTime) {
        guard let moved = RampKeyframes.moving(zoomKeyframes, id: id, to: newStart, duration: duration) else { return }
        commitKeyframes(\.zoomKeyframes, moved, saving: .zoom,
                        actionName: "Move Zoom", coalesceKey: "zoomMove:\(id.uuidString)")
    }

    /// Change a keyframe's hold, clamped against the next keyframe's start.
    func setZoomKeyframeHold(id: UUID, hold: CMTime) {
        guard let updated = RampKeyframes.settingHold(zoomKeyframes, id: id, hold: hold, duration: duration) else { return }
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Hold", coalesceKey: "zoomHold:\(id.uuidString)")
    }

    /// Update a keyframe's peak scale (1.0 … 2.5).
    func setZoomKeyframeScale(id: UUID, scale: CGFloat) {
        guard let idx = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(1.0, min(2.5, scale))
        guard clamped != zoomKeyframes[idx].scale else { return }
        var updated = zoomKeyframes
        updated[idx].scale = clamped
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Scale", coalesceKey: "zoomScale:\(id.uuidString)")
    }

    /// Enter "click to place focus" mode for this keyframe. The editor
    /// preview grows a transparent hit-catcher; the next click inside
    /// the preview rect is routed to `setZoomTarget`. Also seeks the
    /// playhead to the keyframe's peak so the user sees the image at
    /// the zoomed-in moment they're retargeting.
    func beginPlacingZoomTarget(id: UUID) {
        guard let kf = zoomKeyframes.first(where: { $0.id == id }) else { return }
        zoomTargetBeingPlaced = id
        seek(to: kf.peakStartTime)
    }

    /// Cancel focus-placement mode without updating the keyframe.
    /// Wired to both the ESC key and an explicit "Cancel" in the banner.
    func cancelPlacingZoomTarget() {
        zoomTargetBeingPlaced = nil
    }

    /// Apply a user-picked focus point (already converted into
    /// image-pixel coords, bottom-left origin — that's what
    /// `ZoomKeyframe.target` uses and what the compositor consumes).
    func setZoomTarget(id: UUID, imagePixel: CGPoint) {
        guard let idx = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        var updated = zoomKeyframes
        updated[idx].target = imagePixel
        zoomTargetBeingPlaced = nil
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom, actionName: "Set Zoom Focus")
    }

    /// Replace the keyframes with a fresh run of the generator over the
    /// click log, using the current `zoomTuning`. The user asked for it
    /// explicitly, and it's undoable.
    func regenerateZoomFromClicks() {
        let generated = ZoomKeyframeGenerator.generate(
            from: project.eventLog,
            metadata: project.metadata,
            duration: duration,
            config: zoomTuning.config()
        )
        commitKeyframes(\.zoomKeyframes, generated, saving: .zoom, actionName: "Regenerate Zoom")
    }
}
