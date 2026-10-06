import SwiftUI
import AVFoundation
import AppKit

/// Owns the editor's runtime state: the player item (a live composition over
/// raw screen + webcam + original audio), the current overlay overrides,
/// playback + trim state, and the plumbing that keeps the compositor's
/// shared state in sync.
@MainActor
@Observable
final class EditorViewModel {
    // The editor's state and setup live here; what it does is split by
    // area into EditorViewModel+Playback, +Trim, +Captions, +Keyframes,
    // +Audio and +Export. Some state has an internal setter only so
    // those files can update it: views read it and change it through the
    // methods.

    let project: RecordingProject
    let outputSize: CGSize
    let backingScale: CGFloat

    let player: AVPlayer

    private(set) var isLoading = true
    private(set) var loadError: (any Error)?

    // Timeline / playback state
    private(set) var duration: CMTime = .zero
    var currentTime: CMTime = .zero
    var isPlaying: Bool = false
    /// Preview speed, for checking a long recording quickly. Exports
    /// always run at normal speed. `defaultRate` is what `play()` uses,
    /// so Space, a click on the preview and full screen all keep it.
    var playbackRate: Float = 1 {
        didSet {
            player.defaultRate = playbackRate
            if isPlaying { player.rate = playbackRate }
        }
    }
    static let playbackRates: [Float] = [1, 1.25, 1.5, 2]

    /// How far the timeline is zoomed in: 1 fits the whole recording in
    /// the window, 2 shows half of it, and so on. Not saved; each editor
    /// opens fitted. Change it through `setTimelineZoom` (+Playback),
    /// which keeps it in range.
    var timelineZoom: CGFloat = 1

    /// Trim range in composition time. `trimStart` defaults to .zero and
    /// `trimEnd` defaults to the full duration once the composition loads.
    var trimStart: CMTime = .zero { didSet { scheduleEditStateSave() } }
    var trimEnd: CMTime = .zero { didSet { scheduleEditStateSave() } }

    /// Interior cut ranges — regions in source-composition time that have
    /// been excised from the middle of the recording. Sorted, non-
    /// overlapping, strictly inside `[trimStart, trimEnd]`. Mutated via
    /// `insertCut` / `removeCut` / `clearCuts`; use `trimMap` (computed
    /// below) for any read that needs to know the kept ranges.
    var cutRanges: [CMTimeRange] = [] { didSet { scheduleEditStateSave() } }

    /// `edit-state.json` as loaded at open — seeds webcam layout in init
    /// and trim/cuts once the composition's duration is known.
    @ObservationIgnored private let savedEditState: EditState?

    /// Fixed for the life of the editor, so computed once rather than on
    /// every inspector render (a file-exists check and an event-log scan).
    let hasSoundboardTrack: Bool
    let loggedClickCount: Int
    /// When the user clicked, typed or switched apps (seconds, the
    /// composition's time base). A quiet stretch around these is the
    /// user showing something, not dead air, so auto-trim and "Cut long
    /// pauses" leave it in.
    let activityTimes: [TimeInterval]
    @ObservationIgnored private let sidecars = SidecarStore()
    /// Cuts the playback boundary observers were last installed for.
    @ObservationIgnored private var observedCutRanges: [CMTimeRange]?

    /// Derived view of trim + cuts — the editor's single source of truth
    /// for "what's in the output timeline". Built fresh on every read;
    /// TrimMap's initializer re-normalises defensively so this is always
    /// valid even if the inputs drift.
    var trimMap: TrimMap {
        TrimMap(outerTrim: trimRange, cuts: cutRanges)
    }

    /// Anchor for an in-progress range selection. When non-nil, the
    /// selection runs between this point and `selectionEnd`, or
    /// `currentTime` when that's nil (order-independent). Used by the
    /// cut workflow: user hits "Mark" here, scrubs to the other end,
    /// hits "Cut".
    var selectionStart: CMTime?
    /// The other end of a selection Shift-dragged on the timeline. Nil
    /// for a Mark, whose selection follows the playhead instead.
    var selectionEnd: CMTime?

    /// ID of the caption line the user most recently targeted via the
    /// timeline's caption lane. Non-nil values (a) expand the inspector
    /// caption-edit disclosure, (b) scroll that line's row into view,
    /// (c) focus its text field. Cleared by other inspector actions
    /// so selection doesn't linger.
    var focusedCaptionLineId: UUID?

    /// The inspector row that's open (one at a time). Lives here, not in
    /// the view, so the timeline and preview can open a row: clicking a
    /// zoom opens Smart zoom, dragging the webcam opens the webcam row.
    var openInspectorFeature: InspectorFeature?
    /// The zoom picked on the timeline, edited on its own in the Smart
    /// zoom row. Cleared when that zoom is removed.
    var selectedZoomID: UUID?

    /// Convenience: normalised range from `selectionStart` to
    /// `selectionEnd` (or `currentTime`), or nil if no mark is set.
    /// Clamped to the outer trim so you can't select into already-
    /// trimmed regions.
    var selectionRange: CMTimeRange? {
        guard let anchor = selectionStart, duration > .zero else { return nil }
        let a = clamp(anchor, lower: trimStart, upper: trimEnd)
        let b = clamp(selectionEnd ?? currentTime, lower: trimStart, upper: trimEnd)
        let lo = CMTimeCompare(a, b) <= 0 ? a : b
        let hi = CMTimeCompare(a, b) <= 0 ? b : a
        guard CMTimeCompare(hi, lo) > 0 else { return nil }
        return CMTimeRange(start: lo, end: hi)
    }

    // Export state
    var isExporting = false
    var exportProgress: Float = 0
    var exportError: (any Error)?
    var exportTask: Task<Void, Never>?
    /// When the export in progress started, for its time-left estimate.
    var exportStartedAt: Date?
    /// The file the last export saved, while its sheet says so (Show in
    /// Finder, Copy). Nil once that's dismissed.
    var exportedURL: URL?

    /// When non-nil, the preview is in "click to place zoom focus"
    /// mode — the EditorView overlays a hit-catcher that turns the
    /// next click in the preview into a new `target` for this
    /// keyframe. Observable so the UI can draw a banner + change the
    /// row button's label while we wait.
    var zoomTargetBeingPlaced: UUID?

    // AVPlayer observers (torn down in deinit — marked nonisolated(unsafe)
    // so deinit can reference them without @MainActor hops).
    @ObservationIgnored nonisolated(unsafe) var timeObserverToken: Any?
    @ObservationIgnored nonisolated(unsafe) var rateObservation: NSKeyValueObservation?
    /// Boundary observers that seek past each interior cut during
    /// playback. Rebuilt whenever `cutRanges` changes via
    /// `refreshCutBoundaryObservers()`. One token per observer registration.
    @ObservationIgnored nonisolated(unsafe) var cutBoundaryTokens: [Any] = []

    // Editable overlay parameters. `didSet` writes through to the compositor's
    // shared state and nudges the player to redraw if paused.
    var webcamPosition: WebcamPosition {
        didSet {
            if oldValue != webcamPosition {
                // Picking a preset corner supersedes any custom drag
                // placement — otherwise the user would toggle the
                // picker and see nothing happen.
                webcamCustomOrigin = nil
                applyLayout()
                registerUndoableChange(\.webcamPosition, from: oldValue,
                                       actionName: "Change Webcam Position",
                                       coalesceKey: "webcamPosition")
                scheduleEditStateSave()
            }
        }
    }
    /// Explicit drag-placed webcam origin (output-pixel, bottom-left).
    /// Nil means use the preset corner + inset. The editor preview
    /// exposes a drag gesture on the webcam rect that sets this; the
    /// inspector picker clears it when the user switches to a preset.
    var webcamCustomOrigin: CGPoint? {
        didSet {
            if oldValue != webcamCustomOrigin {
                applyLayout()
                registerUndoableChange(\.webcamCustomOrigin, from: oldValue,
                                       actionName: "Move Webcam",
                                       coalesceKey: "webcamCustomOrigin")
                scheduleEditStateSave()
            }
        }
    }
    var webcamShape: WebcamShape {
        didSet {
            if oldValue != webcamShape {
                applyLayout()
                registerUndoableChange(\.webcamShape, from: oldValue,
                                       actionName: "Change Webcam Shape",
                                       coalesceKey: "webcamShape")
                scheduleEditStateSave()
            }
        }
    }
    /// In output pixels.
    var webcamDiameter: CGFloat {
        didSet {
            if oldValue != webcamDiameter {
                applyLayout()
                registerUndoableChange(\.webcamDiameter, from: oldValue,
                                       actionName: "Change Webcam Size",
                                       coalesceKey: "webcamDiameter")
                scheduleEditStateSave()
            }
        }
    }
    /// In output pixels.
    var webcamInset: CGFloat {
        didSet {
            if oldValue != webcamInset {
                applyLayout()
                registerUndoableChange(\.webcamInset, from: oldValue,
                                       actionName: "Change Webcam Inset",
                                       coalesceKey: "webcamInset")
                scheduleEditStateSave()
            }
        }
    }

    /// Auto-generated zoom-in moments derived from the click event log.
    /// Set after the composition loads (we need its duration). Toggleable
    /// from the inspector; persisted to Settings so it survives across
    /// editor sessions.
    var zoomKeyframes: [ZoomKeyframe] = []
    var zoomEnabled: Bool {
        didSet {
            if oldValue != zoomEnabled {
                Settings.shared.editorSmartZoomEnabled = zoomEnabled
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.zoomEnabled, from: oldValue,
                                       actionName: "Toggle Smart Zoom",
                                       coalesceKey: "zoomEnabled")
            }
        }
    }

    /// Webcam fade in / fade out at the start + end of the recording.
    /// Persisted — the user's preferred feel is remembered across edits.
    var webcamTransitions: WebcamTransitions {
        didSet {
            if oldValue != webcamTransitions {
                Settings.shared.editorWebcamTransitions = webcamTransitions
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.webcamTransitions, from: oldValue,
                                       actionName: "Change Webcam Transitions",
                                       coalesceKey: "webcamTransitions")
            }
        }
    }

    /// Cursor click ripples — one ripple per click in the event log,
    /// generated on composition load. Toggle is persisted.
    private(set) var cursorRipples: [CursorRipple] = []
    var cursorRipplesEnabled: Bool {
        didSet {
            if oldValue != cursorRipplesEnabled {
                Settings.shared.editorCursorRipplesEnabled = cursorRipplesEnabled
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.cursorRipplesEnabled, from: oldValue,
                                       actionName: "Toggle Click Ripples",
                                       coalesceKey: "cursorRipplesEnabled")
            }
        }
    }

    /// Manual "talking head" moments. User adds via "Add at playhead";
    /// each keyframe grows the webcam to fill most of the canvas then
    /// shrinks back. Persisted per-recording to `talking-head.json` in
    /// the sidecar so they survive closing + reopening the editor.
    /// Always sorted by `startTime`.
    var talkingHeadKeyframes: [TalkingHeadKeyframe] = []

    /// Peak-amplitude samples for the waveform strip behind the trim
    /// track. Computed asynchronously on editor open so it doesn't
    /// block the loading overlay.
    private(set) var waveformSamples: [Float] = []

    // Stored here because extensions can't hold state.

    /// Visible state for the auto-cut button — prevents double-clicks
    /// while detection is in flight and drives a spinner in the UI.
    var isAutoCutting: Bool = false

    /// Published hint: how many cuts the last auto-cut run inserted.
    /// Nil unless an auto-cut run completed since the editor loaded.
    /// Cleared when the user manually mutates cuts.
    var lastAutoCutCount: Int?

    var polishReport: PolishReport?

    var pendingMenuCommand: MenuCommand?

    /// The Orbis sheet owns its controller's lifetime; this weak link
    /// just lets app-level quit handling find an in-flight upload.
    @ObservationIgnored weak var activeOrbisExport: OrbisExportController?

    // MARK: - Undo / Redo

    /// Standard Cocoa `UndoManager`. Every user-driven editor mutation
    /// registers its inverse here; ⌘Z / ⌘⇧Z in `EditorView` drive it.
    let undoManager = UndoManager()

    /// Bumped whenever the undo stack changes — used to drive SwiftUI
    /// re-evaluation of `canUndo` / `canRedo` + the action-name
    /// tooltips. `UndoManager` is not `@Observable`, so reading its
    /// `canUndo` / `canRedo` directly from views never invalidates.
    /// Reading `undoStackRevision` inside a computed property below
    /// establishes the dependency; every undo registration and
    /// `performUndo` / `performRedo` increments it.
    private(set) var undoStackRevision: Int = 0

    /// SwiftUI-observable accessors that refresh whenever the stack
    /// changes. Views should prefer these over `undoManager.canUndo` /
    /// `undoManager.canRedo` directly.
    var canUndo: Bool {
        _ = undoStackRevision  // dependency
        return undoManager.canUndo
    }
    var canRedo: Bool {
        _ = undoStackRevision
        return undoManager.canRedo
    }
    var undoActionName: String {
        _ = undoStackRevision
        return undoManager.undoActionName
    }
    var redoActionName: String {
        _ = undoStackRevision
        return undoManager.redoActionName
    }

    /// Key of the last coalesceable undo registration. When the same
    /// key is touched again within `undoCoalesceInterval`, the new
    /// registration is suppressed so a slider or handle drag becomes a
    /// single undo step back to its pre-drag value (not dozens of steps).
    @ObservationIgnored private var lastUndoCoalesceKey: AnyHashable?
    @ObservationIgnored private var lastUndoCoalesceTime: Date = .distantPast
    private let undoCoalesceInterval: TimeInterval = 0.5

    /// False for a rapid repeat of `key` (a drag or slider streak) — the
    /// streak's first registration already holds the pre-streak state.
    /// Undo/redo-driven changes always register (so a rapid undo doesn't
    /// swallow the redo) and leave the streak alone.
    private func shouldRegisterUndo(coalescing key: AnyHashable) -> Bool {
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return true }
        let now = Date()
        defer { lastUndoCoalesceTime = now }
        if lastUndoCoalesceKey == key,
           now.timeIntervalSince(lastUndoCoalesceTime) < undoCoalesceInterval {
            return false
        }
        lastUndoCoalesceKey = key
        return true
    }

    /// Register an inverse for a simple property assignment. `oldValue`
    /// is the pre-mutation value (usually captured via `didSet`'s
    /// implicit `oldValue`). `coalesceKey` groups rapid repeat
    /// mutations of the same logical property.
    ///
    /// Safe to call during undo / redo — `UndoManager` detects the
    /// direction and puts the inverse on the right stack.
    func registerUndoableChange<T>(
        _ keyPath: ReferenceWritableKeyPath<EditorViewModel, T>,
        from oldValue: T,
        actionName: String,
        coalesceKey: AnyHashable
    ) {
        guard shouldRegisterUndo(coalescing: coalesceKey) else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target[keyPath: keyPath] = oldValue
        }
        undoManager.setActionName(actionName)
        undoStackRevision &+= 1
    }

    /// Register an inverse for a "snapshot" mutation — an operation that
    /// changes several pieces of state at once, or a value whose setter
    /// doesn't register its own undo. `restore` re-applies a state plus
    /// any follow-up work (applyLayout, save…); the opposite direction is
    /// re-registered each time so redo works indefinitely.
    ///
    /// With a `coalesceKey`, rapid repeats (trim-handle, pill and caption
    /// drags) collapse into one step. The coalesced path used to go
    /// through a reset of the streak key, so every tick of a drag became
    /// its own undo step.
    func registerUndoableSnapshot<State>(
        _ actionName: String,
        coalesceKey: AnyHashable? = nil,
        capture: @escaping (EditorViewModel) -> State,
        oldState: State,
        restore: @escaping (EditorViewModel, State) -> Void
    ) {
        if let coalesceKey {
            guard shouldRegisterUndo(coalescing: coalesceKey) else { return }
        } else {
            // A discrete operation ends any running streak.
            lastUndoCoalesceKey = nil
        }
        registerSnapshotInverse(actionName, capture: capture, oldState: oldState, restore: restore)
    }

    private func registerSnapshotInverse<State>(
        _ actionName: String,
        capture: @escaping (EditorViewModel) -> State,
        oldState: State,
        restore: @escaping (EditorViewModel, State) -> Void
    ) {
        undoManager.registerUndo(withTarget: self) { target in
            let currentState = capture(target)
            restore(target, oldState)
            target.registerSnapshotInverse(actionName, capture: capture, oldState: currentState, restore: restore)
        }
        undoManager.setActionName(actionName)
        undoStackRevision &+= 1
    }

    /// Title cards baked into the export. Defaults load from Settings (or
    /// the built-in defaults on first run). Each change persists, so the
    /// next recording opens with the same title/colors/fade duration. The
    /// `enabled` flag is remembered too — if you always turn cards on,
    /// they'll stay on by default; if you turned them off last time,
    /// they stay off.
    var startCard: TitleCard {
        didSet {
            if oldValue != startCard {
                Settings.shared.editorStartCard = startCard
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.startCard, from: oldValue,
                                       actionName: "Change Start Card",
                                       coalesceKey: "startCard")
            }
        }
    }
    var endCard: TitleCard {
        didSet {
            if oldValue != endCard {
                Settings.shared.editorEndCard = endCard
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.endCard, from: oldValue,
                                       actionName: "Change End Card",
                                       coalesceKey: "endCard")
            }
        }
    }

    /// Export bitrate preset. Persisted across sessions.
    var exportQuality: ExportQuality {
        didSet {
            if oldValue != exportQuality {
                Settings.shared.exportQuality = exportQuality
                registerUndoableChange(\.exportQuality, from: oldValue,
                                       actionName: "Change Export Quality",
                                       coalesceKey: "exportQuality")
            }
        }
    }

    /// Burned-in captions for the mic track. Starts nil until the user
    /// either opens a bundle that already has a `transcription.json` or
    /// runs `generateCaptions()`.
    var transcription: TranscriptionLog?
    /// True while `generateCaptions()` is running; drives the spinner /
    /// disabled state in the inspector.
    var isTranscribing: Bool = false
    /// Surface the last transcription error to the inspector so the user
    /// can see why generation failed (no speech heard, speech model
    /// unavailable, etc).
    var transcriptionError: (any Error)?

    /// Persisted styling for the caption strip. Default is enabled so a
    /// freshly-generated transcription shows immediately.
    var captionStyle: CaptionStyle {
        didSet {
            if oldValue != captionStyle {
                Settings.shared.captionStyle = captionStyle
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.captionStyle, from: oldValue,
                                       actionName: "Change Captions",
                                       coalesceKey: "captionStyle")
            }
        }
    }

    /// Keystroke-overlay chips generated from the event log at editor
    /// load. Regenerated if `keystrokeOverlayStyle.showPlainKeys`
    /// changes (the generator filters at generation time).
    private(set) var keystrokeChips: [KeystrokeChip] = []

    /// Persisted styling + enable flag for the keystroke overlay.
    /// `didSet` regenerates chips when the plain-keys filter flips,
    /// since the generator bakes that filter in.
    var keystrokeOverlayStyle: KeystrokeOverlayStyle {
        didSet {
            if oldValue != keystrokeOverlayStyle {
                Settings.shared.keystrokeOverlayStyle = keystrokeOverlayStyle
                scheduleEditStateSave()
                if oldValue.showPlainKeys != keystrokeOverlayStyle.showPlainKeys {
                    keystrokeChips = KeystrokeOverlayGenerator.generate(
                        from: project.eventLog,
                        showPlainKeys: keystrokeOverlayStyle.showPlainKeys
                    )
                }
                applyLayout()
                registerUndoableChange(\.keystrokeOverlayStyle, from: oldValue,
                                       actionName: "Change Keystrokes",
                                       coalesceKey: "keystrokeOverlayStyle")
            }
        }
    }

    /// Interpolatable cursor-position track (generated from the
    /// sidecar cursor.json at load time). `empty` for older recordings
    /// that don't have a cursor sidecar.
    private(set) var cursorTrack: CursorHighlightTrack = .empty

    /// Write a `.srt` sidecar alongside the exported MP4 when the
    /// recording has a transcription. Persisted — the user rarely
    /// wants to flip this per-export, but we expose the toggle for
    /// the rare "ship the MP4 without subs" case.
    var exportSRTSidecar: Bool {
        didSet {
            if oldValue != exportSRTSidecar {
                Settings.shared.exportSRTSidecar = exportSRTSidecar
            }
        }
    }

    /// Mic noise-reduction preference. When `enabled` flips on, we
    /// run `MicCleaner` offline to produce `mic_cleaned.caf` in the
    /// sidecar (only if the file doesn't already exist at the chosen
    /// strength — we stamp the strength into the file's existence check
    /// by regenerating on strength change), then rebuild the
    /// composition so both preview + export use the cleaned track.
    var noiseReductionStyle: NoiseReductionStyle {
        didSet {
            if oldValue != noiseReductionStyle {
                Settings.shared.noiseReductionStyle = noiseReductionStyle
                scheduleEditStateSave()
                handleNoiseReductionChange(previous: oldValue)
            }
        }
    }

    /// True while `MicCleaner` is generating `mic_cleaned.caf`. Drives
    /// a progress indicator in the inspector — the cleaner runs on a
    /// detached task so UI stays responsive.
    var isCleaningMic: Bool = false

    /// Webcam background style (off / blur / color). Persisted so the
    /// user's chosen mode + blur radius + colour follow them across
    /// recordings. `didSet` re-applies the compositor state so the
    /// preview updates live.
    var webcamBackgroundStyle: WebcamBackgroundStyle {
        didSet {
            if oldValue != webcamBackgroundStyle {
                Settings.shared.webcamBackgroundStyle = webcamBackgroundStyle
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.webcamBackgroundStyle, from: oldValue,
                                       actionName: "Change Webcam Background",
                                       coalesceKey: "webcamBackgroundStyle")
            }
        }
    }

    /// User-facing smart-zoom generator knobs (scale, hold, cluster
    /// sensitivity). Persisted so reopens remember the user's feel.
    /// `didSet` doesn't auto-regenerate — the user explicitly applies
    /// via the "Regenerate from clicks" button so they can preview
    /// slider movement before committing.
    var zoomTuning: ZoomTuning {
        didSet {
            if oldValue != zoomTuning {
                Settings.shared.zoomTuning = zoomTuning
                scheduleEditStateSave()
            }
        }
    }

    /// Persisted styling + enable flag for the cursor halo overlay.
    /// Purely visual; doesn't affect the raw recording.
    var cursorHighlightStyle: CursorHighlightStyle {
        didSet {
            if oldValue != cursorHighlightStyle {
                Settings.shared.cursorHighlightStyle = cursorHighlightStyle
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.cursorHighlightStyle, from: oldValue,
                                       actionName: "Change Cursor Halo",
                                       coalesceKey: "cursorHighlightStyle")
            }
        }
    }

    /// Per-lane visibility overrides. Purely a UI preference — doesn't
    /// affect the baked export. Persisted so the user's chosen layout
    /// follows them across recordings.
    var timelineLanePrefs: TimelineLanePrefs {
        didSet {
            if oldValue != timelineLanePrefs {
                Settings.shared.timelineLanePrefs = timelineLanePrefs
            }
        }
    }

    /// Effective visibility of a secondary timeline lane — combines
    /// the user's stored override with a "has relevant content" rule.
    func isTimelineLaneVisible(_ lane: TimelineLane) -> Bool {
        switch lane {
        case .zoom:
            return resolve(timelineLanePrefs.zoom, auto: !zoomKeyframes.isEmpty)
        case .talkingHead:
            return resolve(timelineLanePrefs.talkingHead, auto: !talkingHeadKeyframes.isEmpty)
        case .soundboard:
            return resolve(timelineLanePrefs.soundboard, auto: !(project.soundboardLog?.events.isEmpty ?? true))
        case .captions:
            return resolve(timelineLanePrefs.captions, auto: !(transcription?.lines.isEmpty ?? true))
        case .keystrokes:
            return resolve(timelineLanePrefs.keystrokes, auto: keystrokeOverlayStyle.enabled)
        }
    }

    private func resolve(_ override: LaneVisibility, auto: Bool) -> Bool {
        switch override {
        case .auto: return auto
        case .show: return true
        case .hide: return false
        }
    }

    /// Per-track audio volumes (mic / system / soundboard). Applied to
    /// both live preview (via `AVPlayerItem.audioMix`) and export (via
    /// `AVAssetReaderAudioMixOutput.audioMix`). Persisted.
    var audioMixVolumes: AudioMixBuilder.Volumes {
        didSet {
            if oldValue != audioMixVolumes {
                Settings.shared.editorAudioMixVolumes = audioMixVolumes
                scheduleEditStateSave()
                rebuildAndApplyAudioMix()
                registerUndoableChange(\.audioMixVolumes, from: oldValue,
                                       actionName: "Change Audio Mix",
                                       coalesceKey: "audioMixVolumes")
            }
        }
    }

    // Retained across the composition's lifetime — needed to rebuild the
    // mix when volumes change without having to re-run EditorComposition.
    private var compositionResult: EditorComposition.Result?

    /// Fraction of the min output dimension — useful for slider range.
    var diameterMax: CGFloat { min(outputSize.width, outputSize.height) * 0.7 }
    var diameterMin: CGFloat { min(outputSize.width, outputSize.height) * 0.08 }

    /// Current webcam bottom-left origin in output-pixel space,
    /// before any talking-head interpolation. Used by the editor's
    /// drag overlay to know where to put the hit-test rect.
    var webcamBaseOrigin: CGPoint {
        if let custom = webcamCustomOrigin { return custom }
        let d = webcamDiameter
        let i = webcamInset
        switch webcamPosition {
        case .bottomRight: return CGPoint(x: outputSize.width - d - i, y: i)
        case .bottomLeft:  return CGPoint(x: i, y: i)
        case .topRight:    return CGPoint(x: outputSize.width - d - i, y: outputSize.height - d - i)
        case .topLeft:     return CGPoint(x: i, y: outputSize.height - d - i)
        case .hidden:      return .zero
        }
    }

    init(project: RecordingProject) {
        self.project = project
        self.outputSize = CGSize(
            width: project.metadata.compositedPixelSize.width,
            height: project.metadata.compositedPixelSize.height
        )
        self.backingScale = CGFloat(project.metadata.backingScale ?? 2.0)

        // A previous editor session's layout wins over capture-time
        // metadata. Trim + cuts are applied in `loadComposition`, once
        // the duration is known to clamp against.
        let saved = EditState.load(from: project.bundle.editStateURL)
        self.savedEditState = saved
        self.hasSoundboardTrack = project.soundboardLog != nil
            || FileManager.default.fileExists(atPath: project.bundle.soundboardAudioURL.path)
        self.loggedClickCount = project.eventLog?.events.filter { $0.type == "click" }.count ?? 0
        self.activityTimes = project.eventLog?.events
            .filter { ["click", "key", "appActivate"].contains($0.type) }
            .map(\.t) ?? []
        let captured = project.metadata.webcamLayout
        let scale = CGFloat(project.metadata.backingScale ?? 2.0)
        self.webcamPosition = saved.flatMap { WebcamPosition(rawValue: $0.webcamPosition) }
            ?? WebcamPosition(rawValue: captured.position) ?? .bottomRight
        self.webcamCustomOrigin = saved?.webcamCustomOrigin.map { CGPoint(x: $0.x, y: $0.y) }
        self.webcamShape = saved.flatMap { WebcamShape(rawValue: $0.webcamShape) }
            ?? WebcamShape(rawValue: captured.shape) ?? .circle
        self.webcamDiameter = saved.map { CGFloat($0.webcamDiameter) } ?? CGFloat(captured.diameterPoints) * scale
        self.webcamInset    = saved.map { CGFloat($0.webcamInset) }    ?? CGFloat(captured.insetPoints) * scale

        // The recording's own look if it's been edited before; otherwise
        // the last-used values from Settings, then the built-in defaults.
        self.zoomEnabled            = saved?.zoomEnabled ?? Settings.shared.editorSmartZoomEnabled
        self.cursorRipplesEnabled   = saved?.cursorRipplesEnabled ?? Settings.shared.editorCursorRipplesEnabled
        self.webcamTransitions      = saved?.webcamTransitions ?? Settings.shared.editorWebcamTransitions ?? .default
        self.startCard              = saved?.startCard ?? Settings.shared.editorStartCard ?? .defaultStart
        self.endCard                = saved?.endCard ?? Settings.shared.editorEndCard ?? .defaultEnd
        self.exportQuality          = Settings.shared.exportQuality
        self.audioMixVolumes        = saved?.audioMixVolumes ?? Settings.shared.editorAudioMixVolumes ?? .unity
        self.captionStyle           = saved?.captionStyle ?? Settings.shared.captionStyle ?? .default
        self.keystrokeOverlayStyle  = saved?.keystrokeOverlayStyle ?? Settings.shared.keystrokeOverlayStyle ?? .default
        self.cursorHighlightStyle   = saved?.cursorHighlightStyle ?? Settings.shared.cursorHighlightStyle ?? .default
        self.zoomTuning             = saved?.zoomTuning ?? Settings.shared.zoomTuning ?? .default
        self.webcamBackgroundStyle  = saved?.webcamBackgroundStyle ?? Settings.shared.webcamBackgroundStyle ?? .default
        self.noiseReductionStyle    = saved?.noiseReductionStyle ?? Settings.shared.noiseReductionStyle ?? .default
        self.exportSRTSidecar       = Settings.shared.exportSRTSidecar
        self.timelineLanePrefs      = Settings.shared.timelineLanePrefs ?? .default
        self.transcription          = project.transcription
        // Build the interpolatable cursor track up-front so the
        // compositor can do a single binary search per frame instead
        // of traversing raw samples each time.
        self.cursorTrack = CursorHighlightTrack.make(
            from: project.cursorLog,
            metadata: project.metadata
        )

        // Load any previously-persisted talking-head moments. If no log
        // exists (fresh recording or pre-persistence bundle), we start
        // empty and the first mutation will create the file.
        if let log = project.talkingHeadLog {
            self.talkingHeadKeyframes = log.keyframes.sorted {
                CMTimeCompare($0.startTime, $1.startTime) < 0
            }
        }

        self.player = AVPlayer()

        // No global state to prime any more — each composition's own
        // `State` instance is created in `EditorComposition.build`
        // (see `compositionResult?.compositorState`). `applyLayout()`
        // writes to it after the composition loads.

        attachPlayerObservers()

        Task { [weak self] in
            await self?.loadComposition()
        }
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        for token in cutBoundaryTokens {
            player.removeTimeObserver(token)
        }
        rateObservation?.invalidate()
        // Pause before tearing down to avoid dangling compositor requests.
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Composition loading

    private func loadComposition() async {
        do {
            let result = try await EditorComposition.build(
                bundle: project.bundle,
                metadata: project.metadata,
                micOverride: effectiveMicOverrideURL()
            )
            self.compositionResult = result
            let item = EditorComposition.makePlayerItem(from: result)
            // Apply initial audio mix (unity or last-used volumes).
            item.audioMix = AudioMixBuilder.build(
                composition: result.composition,
                micTrackID: result.micTrackID,
                systemTrackID: result.systemTrackID,
                soundboardTrackID: result.soundboardTrackID,
                volumes: audioMixVolumes
            )
            player.replaceCurrentItem(with: item)
            observedCutRanges = nil   // new item — reinstall on the next applyLayout
            self.duration = result.duration
            self.trimStart = .zero
            self.trimEnd = result.duration
            // Generate smart-zoom keyframes from the click log now that we
            // know the composition's duration. Push them through to the
            // shared compositor state via applyLayout.
            // Zoom keyframes: prefer the persisted log if the user has
            // edited them in a previous session. Otherwise auto-generate
            // from the click log and persist the result as a starting
            // point — future sessions will load that instead of re-
            // running the generator (so user edits survive).
            if let zoom = project.zoomLog {
                self.zoomKeyframes = zoom.keyframes
            } else {
                self.zoomKeyframes = ZoomKeyframeGenerator.generate(
                    from: project.eventLog,
                    metadata: project.metadata,
                    duration: result.duration
                )
                scheduleSave(.zoom)
            }
            self.cursorRipples = CursorRippleGenerator.generate(
                from: project.eventLog,
                metadata: project.metadata
            )
            self.keystrokeChips = KeystrokeOverlayGenerator.generate(
                from: project.eventLog,
                showPlainKeys: self.keystrokeOverlayStyle.showPlainKeys
            )

            // Restore a previous session's trim + cuts; only a recording
            // that's never been edited gets auto-trimmed. Either way this
            // runs before flipping isLoading so the editor window appears
            // with the trim already applied (no "full → trimmed" snap).
            if let saved = savedEditState {
                let dur = result.duration
                let start = clamp(CMTime(seconds: saved.trimStart, preferredTimescale: 600), lower: .zero, upper: dur)
                let end = clamp(CMTime(seconds: saved.trimEnd, preferredTimescale: 600), lower: start, upper: dur)
                if CMTimeCompare(end, start) > 0 {
                    self.trimStart = start
                    self.trimEnd = end
                }
                let restoredCuts = saved.cuts.map {
                    CMTimeRange(
                        start: CMTime(seconds: $0.start, preferredTimescale: 600),
                        end: CMTime(seconds: $0.end, preferredTimescale: 600)
                    )
                }
                // TrimMap re-normalises (sorted, merged, inside the trim).
                self.cutRanges = TrimMap(outerTrim: trimRange, cuts: restoredCuts).cuts
                PepperDebug.log("EDITOR: restored edit state trim \(CMTimeGetSeconds(self.trimStart))..\(CMTimeGetSeconds(self.trimEnd))s, \(self.cutRanges.count) cut(s)")
            } else if let speech = await SilenceAnalyzer.detectContentRange(
                audioURL: project.bundle.micAudioURL,
                duration: result.duration
            ) {
                let detected = SilenceAnalyzer.widening(speech, toKeep: activityTimes, duration: result.duration)
                self.trimStart = detected.start
                self.trimEnd   = detected.end
                PepperDebug.log("EDITOR: auto-trim \(CMTimeGetSeconds(detected.start))..\(CMTimeGetSeconds(detected.end))s")
            }

            applyLayout()
            // Open on the video's first kept frame. Auto-trim usually
            // moves the In point past 0:00, and the preview used to open
            // on a frame that isn't in the video.
            seek(to: trimStart)
            isLoading = false
            PepperDebug.log("EDITOR: zoom keyframes generated: \(self.zoomKeyframes.count)")

            // Kick off the waveform sampler in the background. The
            // editor is already usable — the strip just pops in when
            // ready. Typical 60s recording samples in well under 100ms.
            Task { [weak self] in
                guard let self else { return }
                let samples = await WaveformSampler.sample(audioURL: self.project.bundle.micAudioURL)
                await MainActor.run { self.waveformSamples = samples }
            }
        } catch {
            loadError = error
            isLoading = false
            PepperDebug.log("EDITOR: composition load failed: \(error)")
        }
    }

    /// Swap in a fresh composition — noise reduction switched the mic
    /// source — without touching any edit. `loadComposition` used to be
    /// re-run for this, which reset the trim, re-ran auto-trim and
    /// reloaded zoom keyframes from the stale snapshot taken at open.
    /// Each composition owns a new compositor `State`, so re-apply the
    /// layout, then restore the playhead and play state.
    func rebuildComposition() async {
        guard compositionResult != nil else { return }
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        do {
            let result = try await EditorComposition.build(
                bundle: project.bundle,
                metadata: project.metadata,
                micOverride: effectiveMicOverrideURL()
            )
            self.compositionResult = result
            let item = EditorComposition.makePlayerItem(from: result)
            item.audioMix = AudioMixBuilder.build(
                composition: result.composition,
                micTrackID: result.micTrackID,
                systemTrackID: result.systemTrackID,
                soundboardTrackID: result.soundboardTrackID,
                volumes: audioMixVolumes
            )
            player.replaceCurrentItem(with: item)
            observedCutRanges = nil   // new item — reinstall on the next applyLayout
            applyLayout()
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            PepperDebug.log("EDITOR: composition rebuild failed: \(error)")
        }
    }

    // MARK: - Edit-state persistence

    /// Sidecar files the editor writes, each through `sidecars` (debounced).
    enum SidecarFile: Hashable {
        case editState, zoom, talkingHead, transcription
    }

    func scheduleSave(_ file: SidecarFile) {
        sidecars.schedule(url(for: file)) { try self.contents(of: file) }
    }

    func saveNow(_ file: SidecarFile) {
        sidecars.writeNow(url(for: file)) { try self.contents(of: file) }
    }

    /// Write anything pending immediately. Called when the editor window
    /// closes and when the app quits.
    func flushPendingSaves() {
        sidecars.flush()
    }

    /// Skipped during the initial load — only user edits (and undo/redo
    /// of them) are persisted.
    private func scheduleEditStateSave() {
        guard !isLoading else { return }
        scheduleSave(.editState)
    }

    private func url(for file: SidecarFile) -> URL {
        switch file {
        case .editState:     return project.bundle.editStateURL
        case .zoom:          return project.bundle.zoomURL
        case .talkingHead:   return project.bundle.talkingHeadURL
        case .transcription: return project.bundle.transcriptionURL
        }
    }

    /// What `file` should contain right now; nil removes it.
    private func contents(of file: SidecarFile) throws -> Data? {
        switch file {
        case .editState:
            return try SidecarStore.json(currentEditState())
        case .zoom:
            // An empty array is written, not the file removed: a missing
            // zoom.json means "never edited" and triggers regeneration on
            // the next open, which resurrected every zoom the user deleted.
            return try SidecarStore.json(ZoomLog(version: 1, keyframes: zoomKeyframes))
        case .talkingHead:
            // No moments → no file, rather than an empty-array file.
            guard !talkingHeadKeyframes.isEmpty else { return nil }
            return try SidecarStore.json(TalkingHeadLog(version: 1, keyframes: talkingHeadKeyframes))
        case .transcription:
            guard let transcription else { return nil }
            return try SidecarStore.json(transcription, dates: .iso8601)
        }
    }

    private func currentEditState() -> EditState {
        EditState(
            trimStart: CMTimeGetSeconds(trimStart),
            trimEnd: CMTimeGetSeconds(trimEnd),
            cuts: cutRanges.map {
                EditState.Cut(start: CMTimeGetSeconds($0.start), end: CMTimeGetSeconds($0.end))
            },
            webcamPosition: webcamPosition.rawValue,
            webcamShape: webcamShape.rawValue,
            webcamDiameter: Double(webcamDiameter),
            webcamInset: Double(webcamInset),
            webcamCustomOrigin: webcamCustomOrigin.map {
                EditState.Point(x: Double($0.x), y: Double($0.y))
            },
            webcamTransitions: webcamTransitions,
            startCard: startCard,
            endCard: endCard,
            zoomEnabled: zoomEnabled,
            cursorRipplesEnabled: cursorRipplesEnabled,
            audioMixVolumes: audioMixVolumes,
            captionStyle: captionStyle,
            keystrokeOverlayStyle: keystrokeOverlayStyle,
            cursorHighlightStyle: cursorHighlightStyle,
            zoomTuning: zoomTuning,
            webcamBackgroundStyle: webcamBackgroundStyle,
            noiseReductionStyle: noiseReductionStyle
        )
    }

    /// Run undo + refresh observation state. Callers (buttons + ⌘Z
    /// handler) should use this instead of calling `undoManager.undo()`
    /// directly — it guarantees `canUndo` / `canRedo` / action names
    /// re-read correctly afterwards.
    func performUndo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        undoStackRevision &+= 1
        // A drag right after an undo/redo starts a fresh undo step.
        lastUndoCoalesceKey = nil
    }

    func performRedo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        undoStackRevision &+= 1
        // A drag right after an undo/redo starts a fresh undo step.
        lastUndoCoalesceKey = nil
    }

    /// Currently-selected trim range, or the full duration when the user
    /// hasn't narrowed it.
    var trimRange: CMTimeRange {
        CMTimeRange(start: trimStart, end: trimEnd)
    }

    func clamp(_ t: CMTime, lower: CMTime, upper: CMTime) -> CMTime {
        if CMTimeCompare(t, lower) < 0 { return lower }
        if CMTimeCompare(t, upper) > 0 { return upper }
        return t
    }

    // MARK: - Layout

    /// Rebuild `player.currentItem.audioMix` from the current volumes.
    /// Called by the `audioMixVolumes` didSet so preview updates as the
    /// user drags a mix slider.
    private func rebuildAndApplyAudioMix() {
        guard let result = compositionResult,
              let item = player.currentItem else { return }
        item.audioMix = AudioMixBuilder.build(
            composition: result.composition,
            micTrackID: result.micTrackID,
            systemTrackID: result.systemTrackID,
            soundboardTrackID: result.soundboardTrackID,
            volumes: audioMixVolumes
        )
    }

    func applyLayout() {
        // An export renders from a snapshot of these values in its own
        // composition, so the preview isn't needed for correctness — but
        // it's held still mid-export so it keeps showing what's being
        // rendered rather than edits that won't be in this file.
        guard !isExporting else { return }
        guard let state = compositionResult?.compositorState else { return }
        state.set(currentOverlay(), trimMap: trimMap)
        // Boundary observers only change with the cuts; applyLayout runs on
        // every slider tick and used to reinstall them each time.
        if observedCutRanges != cutRanges {
            refreshCutBoundaryObservers()
            observedCutRanges = cutRanges
        }
        forceRedraw()
    }
}
