import SwiftUI
import AVFoundation
import AppKit

/// The parts of the editor that depend on the playhead, each its own
/// view. `currentTime` changes ~30×/s during playback, and SwiftUI
/// re-renders whichever view read it: read inline, it re-rendered the
/// whole inspector (including a synchronous title-card image load) and
/// every timeline lane, pill and the waveform on each tick.
struct PlayheadTimeLabel: View {
    let viewModel: EditorViewModel

    var body: some View {
        Text(TimelineMath.timeString(viewModel.currentTime))
            .brandTimecode(11)
    }
}

struct PlayheadLine: View {
    let viewModel: EditorViewModel
    let width: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        let x = TimelineMath.x(for: viewModel.currentTime, duration: viewModel.duration, width: width)
        // Persimmon, the brand's "live / now" colour (Muesli's recording red).
        Rectangle()
            .fill(Brand.live)
            .frame(width: 2, height: trackHeight + 6)
            .offset(x: max(0, min(width - 2, x - 1)), y: -3)
            .allowsHitTesting(false)
            .shadow(color: Brand.live.opacity(0.4), radius: 2)
    }
}

/// `selectionRange` follows the playhead while a mark is set.
struct SelectionWash: View {
    let viewModel: EditorViewModel
    let width: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        if let sel = viewModel.selectionRange {
            let a = TimelineMath.x(for: sel.start, duration: viewModel.duration, width: width)
            let b = TimelineMath.x(for: sel.end, duration: viewModel.duration, width: width)
            Rectangle()
                .fill(Brand.live.opacity(0.3))
                .frame(width: max(0, b - a), height: trackHeight)
                .offset(x: a)
                .allowsHitTesting(false)
        }
    }
}

/// Enabled only for a non-empty selection — which follows the playhead
/// while a mark is set.
struct CutSelectionButton: View {
    let viewModel: EditorViewModel

    var body: some View {
        Button {
            viewModel.cutSelection()
        } label: {
            Label("Cut", systemImage: "scissors")
        }
        .keyboardShortcut("o", modifiers: .shift)
        .disabled(viewModel.selectionRange == nil)
        .help("Cut the selected part (Delete or ⇧O); the rest of the video closes up")
    }
}

/// Keeps the playhead in view on a zoomed timeline. Playing carries it
/// off the right edge, so the view pages along with it; a jump elsewhere
/// (a step key, a click in the inspector) brings it to the middle.
/// Leaves it be while you drag on the track, and after you scroll away
/// with the playhead still. Its own view because it reads `currentTime`
/// (see `PlayheadTimeLabel`).
struct PlayheadFollower: View {
    let viewModel: EditorViewModel
    let width: CGFloat
    let viewport: CGFloat
    let scrollX: CGFloat
    let isScrubbing: Bool
    let scrollTo: (CGFloat) -> Void

    var body: some View {
        Color.clear
            .onChange(of: viewModel.currentTime) { _, time in
                guard width > viewport + 1, !isScrubbing else { return }
                let x = TimelineMath.x(for: time, duration: viewModel.duration, width: width)
                let margin: CGFloat = 24
                let target: CGFloat
                if viewModel.isPlaying {
                    guard x < scrollX || x > scrollX + viewport - margin else { return }
                    target = x - margin
                } else {
                    guard x < scrollX || x > scrollX + viewport else { return }
                    target = x - viewport / 2
                }
                scrollTo(max(0, min(width - viewport, target)))
            }
    }
}

/// Where the pointer is on the main track, for `HoverTimeReadout`. A
/// class held in `@State`, so a pointer move re-renders only the
/// readout: `TimelineView` itself never reads `x`.
@Observable
final class TimelineHover {
    var x: CGFloat?
}

/// A hairline and the time under the pointer on the main track, to see
/// where a click will land before making it.
struct HoverTimeReadout: View {
    let hover: TimelineHover
    let viewModel: EditorViewModel
    let width: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        if let x = hover.x, width > 0 {
            let label: CGFloat = 52
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1, height: trackHeight)
                    .offset(x: x)
                Text(TimelineMath.timeString(TimelineMath.time(atX: x, duration: viewModel.duration, width: width)))
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    // Right of the line, or left of it near the end.
                    .offset(x: x + 4 + label > width ? x - 4 - label : x + 4, y: 2)
            }
            .frame(width: width, height: trackHeight, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }
}

struct TimelineView: View {
    @Bindable var viewModel: EditorViewModel

    static let mainTrackHeight: CGFloat = 40
    private let trackHeight: CGFloat = TimelineView.mainTrackHeight
    private let handleWidth: CGFloat = 12
    /// Room above and below the lanes for the playhead's overhang and
    /// the trim handles' shadows, which the scroll view would clip.
    private static let laneInset: CGFloat = 3
    /// The main track's own space, so the scrub gesture reads the same
    /// x whether it starts on the track or on a cut.
    private static let trackSpace = "pepper.timeline.track"

    /// Whether the drag in progress selects (Shift held when it began)
    /// or just moves the playhead. Nil between drags.
    @State private var scrubSelecting: Bool?
    /// The cut under the pointer, which shows its Put Back button.
    @State private var hoveredCut: Int?
    /// The controls bar is too narrow for its buttons' names.
    @State private var compactControls = false
    @State private var hover = TimelineHover()

    // Zoom: the lanes scroll sideways when zoomed in.
    @State private var scrollPosition = ScrollPosition()
    /// How far the lanes are scrolled, as the scroll view reports it.
    @State private var scrollX: CGFloat = 0
    /// A pinch in progress: the zoom it started from, and the time under
    /// the fingers, kept there as it zooms.
    @State private var pinch: (zoom: CGFloat, time: CMTime, screenX: CGFloat)?

    /// The lanes' height: the track, each visible lane and the gaps, and
    /// a scroll bar under a zoomed timeline where scroll bars take room
    /// (a mouse attached, or Show scroll bars set to Always). EditorView
    /// sizes the timeline strip from it.
    static func lanesHeight(_ vm: EditorViewModel) -> CGFloat {
        var h = mainTrackHeight + laneInset * 2
        for lane in TimelineLane.allCases where vm.isTimelineLaneVisible(lane) {
            h += (lane == .zoom ? 18 : 14) + 6
        }
        if vm.timelineZoom > 1, NSScroller.preferredScrollerStyle == .legacy {
            h += NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        return h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            lanes
            controls
        }
        .animation(
            .easeInOut(duration: 0.18),
            value: [
                viewModel.isTimelineLaneVisible(.zoom),
                viewModel.isTimelineLaneVisible(.talkingHead),
                viewModel.isTimelineLaneVisible(.soundboard),
                viewModel.isTimelineLaneVisible(.captions),
                viewModel.isTimelineLaneVisible(.keystrokes)
            ]
        )
    }

    // MARK: Lanes and zoom

    /// The track and its lanes, as wide as the zoom makes them, in a
    /// sideways scroll view; the header and controls stay put. At zoom 1
    /// that's exactly the window's width, as before zoom existed. Every
    /// lane maps time across the full `width`, so none of them needed
    /// to know about zooming.
    private var lanes: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let width = viewport * viewModel.timelineZoom
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 6) {
                    track(width: width)
                        .frame(width: width, height: trackHeight)

                    // Secondary lanes — each one is conditional on the
                    // viewModel's effective visibility rule (user override +
                    // "has data" fallback). Hiding removes the row from the
                    // stack so the bottom controls lift up, no empty stripes.
                    if viewModel.isTimelineLaneVisible(.zoom) {
                        zoomLane(width: width)
                            .frame(width: width, height: 18)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if viewModel.isTimelineLaneVisible(.talkingHead) {
                        talkingHeadLane(width: width)
                            .frame(width: width, height: 14)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if viewModel.isTimelineLaneVisible(.soundboard) {
                        cueLane(width: width)
                            .frame(width: width, height: 14)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if viewModel.isTimelineLaneVisible(.captions) {
                        captionsLane(width: width)
                            .frame(width: width, height: 14)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if viewModel.isTimelineLaneVisible(.keystrokes) {
                        keystrokesLane(width: width)
                            .frame(width: width, height: 14)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.vertical, Self.laneInset)
            }
            .scrollIndicators(viewModel.timelineZoom > 1 ? .visible : .hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                scrollX = x
            }
            .background {
                PlayheadFollower(viewModel: viewModel, width: width, viewport: viewport,
                                 scrollX: scrollX, isScrubbing: scrubSelecting != nil) { x in
                    scrollPosition.scrollTo(x: x)
                }
            }
            .simultaneousGesture(pinchGesture(viewport: viewport))
            .onChange(of: viewModel.timelineZoom) { old, new in
                keepPlaceWhileZooming(from: old, to: new, viewport: viewport)
            }
        }
        .frame(height: Self.lanesHeight(viewModel))
    }

    /// Pinch on the timeline to zoom, around the point between your
    /// fingers.
    private func pinchGesture(viewport: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch == nil {
                    let x = value.startLocation.x
                    let width = viewport * viewModel.timelineZoom
                    pinch = (viewModel.timelineZoom, timeForX(scrollX + x, width: width), x)
                }
                if let pinch {
                    viewModel.setTimelineZoom(pinch.zoom * value.magnification)
                }
            }
            .onEnded { _ in pinch = nil }
    }

    /// Zooming keeps your place: the time under a pinch stays under it;
    /// otherwise the playhead stays where it is on screen, or, when it's
    /// out of view, whatever is in the middle stays in the middle.
    private func keepPlaceWhileZooming(from old: CGFloat, to new: CGFloat, viewport: CGFloat) {
        let oldWidth = viewport * old
        let newWidth = viewport * new
        let anchor: (time: CMTime, screenX: CGFloat)
        if let pinch {
            anchor = (pinch.time, pinch.screenX)
        } else {
            let playheadX = xForTime(viewModel.currentTime, width: oldWidth) - scrollX
            anchor = (0...viewport).contains(playheadX)
                ? (viewModel.currentTime, playheadX)
                : (timeForX(scrollX + viewport / 2, width: oldWidth), viewport / 2)
        }
        let target = max(0, min(newWidth - viewport, xForTime(anchor.time, width: newWidth) - anchor.screenX))
        // Next turn, once the new width has laid out: the scroll view
        // would clamp the offset to the old one.
        DispatchQueue.main.async { scrollPosition.scrollTo(x: target) }
    }

    private var zoomButtons: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.zoomTimelineOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(viewModel.timelineZoom <= 1)
            .help("Zoom out (⌘−). ⌘0 fits the whole recording.")
            Button {
                viewModel.zoomTimelineIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(viewModel.timelineZoom >= viewModel.maxTimelineZoom)
            .help("Zoom in (⌘+), or pinch on the timeline")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Keystroke lane

    @ViewBuilder
    private func keystrokesLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Brand.chip.opacity(0.6))

            // Each chip is a point-in-time event, like a soundboard
            // cue. Render as a fixed-width yellow capsule so a burst
            // of keystrokes reads as a cluster rather than one long
            // bar. Width of 4pt keeps even a rapid ⌘S⌘Enter duo
            // distinguishable.
            ForEach(viewModel.keystrokeChips) { chip in
                let x = xForTime(chip.time, width: width)
                Capsule()
                    .fill(Brand.accentText.opacity(0.85))
                    .frame(width: 4, height: 10)
                    .offset(x: max(0, min(width - 4, x - 2)))
                    .help("\(timeString(chip.time)): \(chip.label)")
                    .onTapGesture {
                        viewModel.seek(to: chip.time)
                        viewModel.openInspectorFeature = .keystrokes
                    }
            }
        }
    }

    // MARK: Caption lane

    @ViewBuilder
    private func captionsLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Brand.chip.opacity(0.6))

            ForEach(viewModel.transcription?.lines ?? []) { line in
                let startTime = CMTime(seconds: line.startSeconds, preferredTimescale: 600)
                let endTime = CMTime(seconds: line.endSeconds, preferredTimescale: 600)
                let a = xForTime(startTime, width: width)
                let b = xForTime(endTime, width: width)
                // Range pill — width matches the line's display duration,
                // collapsed to a minimum 3pt so very short lines stay
                // clickable. Fill colour flips to accent when this line
                // is the focused one, so after clicking the pill you can
                // see which row the inspector jumped to.
                let isFocused = viewModel.focusedCaptionLineId == line.id
                let w = max(3, b - a)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isFocused ? Color.accentColor : Brand.teal.opacity(0.85))
                    .frame(width: w, height: 10)
                    .offset(x: max(0, min(width - w, a)))
                    .help("\(timeString(startTime)): \(line.text)")
                    .onTapGesture {
                        viewModel.seek(to: startTime)
                        viewModel.focusedCaptionLineId = line.id
                    }
            }
        }
    }

    // MARK: Soundboard cue lane

    @ViewBuilder
    private func cueLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Brand.chip.opacity(0.6))

            ForEach(viewModel.project.soundboardLog?.events ?? [], id: \.cueID) { fire in
                let cueTime = CMTime(seconds: fire.t, preferredTimescale: 600)
                let x = xForTime(cueTime, width: width)
                // Fixed-width orange pill centred on the fire instant —
                // cue triggers are point-in-time events, not ranges.
                Capsule()
                    .fill(Brand.live.opacity(0.85))
                    .frame(width: 6, height: 10)
                    .offset(x: max(0, min(width - 6, x - 3)))
                    .help("\(fire.cueName) • \(timeString(cueTime))")
                    .onTapGesture {
                        viewModel.seek(to: cueTime)
                    }
            }
        }
    }

    // MARK: Talking-head keyframe lane

    @ViewBuilder
    private func talkingHeadLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Brand.chip.opacity(0.6))

            ForEach(viewModel.talkingHeadKeyframes) { kf in
                KeyframePill(
                    viewModel: viewModel,
                    kf: kf,
                    trackWidth: width,
                    height: 10,
                    color: Brand.emerald.opacity(0.8),
                    help: "Talking head at \(TimelineMath.timeString(kf.startTime)) — drag to move, right-edge to resize",
                    onMove: { viewModel.moveTalkingHeadKeyframe(id: $0, to: $1) },
                    onSetHold: { viewModel.setTalkingHeadHold(id: $0, hold: $1) },
                    onSelect: { _ in viewModel.openInspectorFeature = .webcam }
                )
            }
        }
    }

    // MARK: Zoom keyframe lane

    @ViewBuilder
    private func zoomLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Brand.chip.opacity(0.8))

            ForEach(viewModel.zoomKeyframes) { kf in
                KeyframePill(
                    viewModel: viewModel,
                    kf: kf,
                    trackWidth: width,
                    height: 12,
                    color: Brand.violet.opacity(viewModel.selectedZoomID == kf.id ? 1 : (viewModel.zoomEnabled ? 0.75 : 0.3)),
                    help: "Zoom \(String(format: "%.2f×", kf.scale)) at \(TimelineMath.timeString(kf.startTime)) — drag to move, right-edge to resize",
                    onMove: { viewModel.moveZoomKeyframe(id: $0, to: $1) },
                    onSetHold: { viewModel.setZoomKeyframeHold(id: $0, hold: $1) },
                    onSelect: { id in
                        viewModel.selectedZoomID = id
                        viewModel.openInspectorFeature = .zoom
                    }
                )
            }
        }
    }

    // MARK: Header (time labels)

    @ViewBuilder
    private var header: some View {
        HStack {
            PlayheadTimeLabel(viewModel: viewModel)
            Spacer()
            // What will be exported: the trim less every cut. It used to
            // read "00:03.2 → 01:45.0 (101.8s)", the trim alone, so a
            // video with cuts looked longer than it was.
            Text("Final video \(InspectorFormat.time(viewModel.trimMap.outputDuration))")
                .brandTimecode(10.5, weight: .regular)
                .foregroundStyle(.secondary)
                .help("How long the video will be, after trimming and cuts")
            Spacer()
            Text(timeString(viewModel.duration))
                .brandTimecode(11)
                .foregroundStyle(.secondary)
                .help("The whole recording")
            zoomButtons
                .padding(.leading, 6)
            laneVisibilityMenu
                .padding(.leading, 2)
        }
    }

    /// Popover-style menu that exposes per-lane Auto/Show/Hide state
    /// plus global Show-all / Hide-all / Reset-to-Auto shortcuts. The
    /// lane's current resolved visibility shows as a checkmark so the
    /// user can tell at a glance what's on screen.
    @ViewBuilder
    private var laneVisibilityMenu: some View {
        Menu {
            ForEach(TimelineLane.allCases) { lane in
                Menu {
                    ForEach(LaneVisibility.allCases, id: \.self) { option in
                        Button {
                            var p = viewModel.timelineLanePrefs
                            p[lane] = option
                            viewModel.timelineLanePrefs = p
                        } label: {
                            if viewModel.timelineLanePrefs[lane] == option {
                                Label(option.menuLabel, systemImage: "checkmark")
                            } else {
                                Text(option.menuLabel)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(lane.menuLabel)
                        Spacer()
                        if viewModel.isTimelineLaneVisible(lane) {
                            Image(systemName: "eye")
                        } else {
                            Image(systemName: "eye.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            Button("Show All Lanes") {
                viewModel.timelineLanePrefs = viewModel.timelineLanePrefs.all(.show)
            }
            Button("Hide All Lanes") {
                viewModel.timelineLanePrefs = viewModel.timelineLanePrefs.all(.hide)
            }
            Button("Reset to Auto") {
                viewModel.timelineLanePrefs = viewModel.timelineLanePrefs.all(.auto)
            }
        } label: {
            Image(systemName: "square.3.layers.3d.down.forward")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
        .help("Choose which timeline lanes to show")
    }

    // MARK: Track

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let startX = xForTime(viewModel.trimStart, width: width)
        let endX = xForTime(viewModel.trimEnd, width: width)

        ZStack(alignment: .leading) {
            // Base track
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Brand.chip)

            // Waveform behind everything else — subtle, doesn't fight
            // with the trim handles or playhead.
            WaveformStripView(samples: viewModel.waveformSamples)
                .frame(width: width, height: trackHeight)
                .opacity(0.45)
                .allowsHitTesting(false)

            // Active trim region highlight
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: max(0, endX - startX))
                .offset(x: startX)

            // Dimmed pre-trim. Washed toward the ground colour so it fades
            // in both modes; black turned light mode into a grey slab.
            Rectangle()
                .fill(Brand.ground.opacity(0.7))
                .frame(width: max(0, startX))

            // Dimmed post-trim
            Rectangle()
                .fill(Brand.ground.opacity(0.7))
                .frame(width: max(0, width - endX))
                .offset(x: endX)

            // Interior cuts — rendered as dark hatched regions so they
            // read as "not in the output". Drawn ABOVE the active-trim
            // highlight but BELOW the seek layer + handles; their clicks
            // land on the cut layer above the seek layer.
            ForEach(Array(viewModel.cutRanges.enumerated()), id: \.offset) { _, cut in
                let a = xForTime(cut.start, width: width)
                let b = xForTime(cut.end, width: width)
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                    // Diagonal hatch lines in a subtle tint so the
                    // region reads as "cut" even without color.
                    GeometryReader { geo in
                        let size = geo.size
                        let step: CGFloat = 6
                        Path { p in
                            var x: CGFloat = -size.height
                            while x < size.width + size.height {
                                p.move(to: CGPoint(x: x, y: size.height))
                                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                                x += step
                            }
                        }
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                }
                .frame(width: max(0, b - a), height: trackHeight)
                .offset(x: a)
                .allowsHitTesting(false)
            }

            // Active range selection — drawn as an orange wash so it's
            // clearly distinct from trim + cuts. Only visible while the
            // user has hit "Mark" and is scrubbing.
            SelectionWash(viewModel: viewModel, width: width, trackHeight: trackHeight)

            // Click/drag-to-seek layer (below handles)
            Color.clear
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: width))

            // Each cut, above the seek layer: scrubbing carries on across
            // it, and pointing at it shows a button to put it back (also
            // on its right-click menu). Restoring a cut used to mean
            // finding it in the Cuts list.
            ForEach(Array(viewModel.cutRanges.enumerated()), id: \.offset) { idx, cut in
                let a = xForTime(cut.start, width: width)
                let w = max(0, xForTime(cut.end, width: width) - a)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: w, height: trackHeight)
                    .overlay {
                        if hoveredCut == idx, w >= 20 {
                            Button {
                                hoveredCut = nil
                                viewModel.removeCut(at: idx)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .font(.system(size: 15))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.black, .white)
                                    .shadow(color: .black.opacity(0.4), radius: 2)
                            }
                            .buttonStyle(.plain)
                            .help("Put this part back in the video")
                            .accessibilityLabel("Put back the cut at \(InspectorFormat.time(cut.start))")
                        }
                    }
                    .onHover { inside in
                        if inside { hoveredCut = idx } else if hoveredCut == idx { hoveredCut = nil }
                    }
                    .gesture(scrubGesture(width: width))
                    .contextMenu {
                        Button("Put Back This Cut") {
                            hoveredCut = nil
                            viewModel.removeCut(at: idx)
                        }
                    }
                    .help("\(InspectorFormat.time(cut.start))–\(InspectorFormat.time(cut.end)) is cut from the video. Right-click to put it back.")
                    .offset(x: a)
            }

            // Left trim handle
            TrimHandle()
                .frame(width: handleWidth, height: trackHeight)
                .offset(x: clampHandleOffset(startX - handleWidth / 2, width: width))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let t = timeForX(value.location.x + handleWidth / 2, width: width)
                            viewModel.setTrimStart(t)
                        }
                )

            // Right trim handle
            TrimHandle()
                .frame(width: handleWidth, height: trackHeight)
                .offset(x: clampHandleOffset(endX - handleWidth / 2, width: width))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let t = timeForX(value.location.x + handleWidth / 2, width: width)
                            viewModel.setTrimEnd(t)
                        }
                )

            // Playhead (non-interactive visual)
            PlayheadLine(viewModel: viewModel, width: width, trackHeight: trackHeight)

            HoverTimeReadout(hover: hover, viewModel: viewModel, width: width, trackHeight: trackHeight)
        }
        .coordinateSpace(.named(Self.trackSpace))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover.x = point.x
            case .ended:             hover.x = nil
            }
        }
    }

    /// Click or drag to move the playhead. Holding Shift as the drag
    /// starts selects the part dragged across instead, for Delete or
    /// Cut, without the Mark-scrub-Cut steps. A plain click drops that
    /// selection again.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackSpace))
            .onChanged { value in
                let t = timeForX(value.location.x, width: width)
                if scrubSelecting == nil {
                    let selecting = NSEvent.modifierFlags.contains(.shift)
                    scrubSelecting = selecting
                    if !selecting { viewModel.clearDraggedSelection() }
                }
                if scrubSelecting == true {
                    viewModel.selectRange(from: timeForX(value.startLocation.x, width: width), to: t)
                }
                viewModel.seek(to: t)
            }
            .onEnded { _ in scrubSelecting = nil }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause (Space)")

            // A button showing the speed, not a pop-up: the bar is short
            // of room at the editor's default size.
            Menu {
                Picker("Speed", selection: $viewModel.playbackRate) {
                    ForEach(EditorViewModel.playbackRates, id: \.self) { rate in
                        Text(Self.rateLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(Self.rateLabel(viewModel.playbackRate))
                    .monospacedDigit()
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed, for checking the video. Exports play at normal speed.")
            .accessibilityLabel("Playback speed")

            Divider().frame(height: 16)

            Button {
                viewModel.performUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            .help(undoTooltip)

            Button {
                viewModel.performRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)
            .help(redoTooltip)

            Divider().frame(height: 16)

            Button {
                viewModel.setTrimStartToCurrent()
            } label: {
                Label("Set In", systemImage: "arrow.down.to.line.compact")
            }
            .keyboardShortcut("i", modifiers: [])
            .help("Set trim in-point to playhead (I)")

            Button {
                viewModel.setTrimEndToCurrent()
            } label: {
                Label("Set Out", systemImage: "arrow.up.to.line.compact")
            }
            .keyboardShortcut("o", modifiers: [])
            .help("Set trim out-point to playhead (O)")

            // Not Undo's arrow, which sits two buttons along.
            Button {
                viewModel.clearTrim()
            } label: {
                Label("Reset", systemImage: "arrow.left.and.right")
            }
            .help("Reset the trim to the whole recording")

            Button {
                viewModel.autoTrimSilence()
            } label: {
                Label("Auto-trim", systemImage: "waveform.path.ecg")
            }
            .help("Re-run silence detection on the mic track")

            Divider().frame(height: 16)

            Button {
                viewModel.markSelectionStart()
            } label: {
                Label("Mark", systemImage: "flag")
            }
            .keyboardShortcut("i", modifiers: .shift)
            .help("Anchor a selection at the playhead (⇧I)")

            CutSelectionButton(viewModel: viewModel)

            Spacer()

            // The preview has no controls of its own (this bar is the
            // one transport), so full screen lives here.
            Button {
                FullScreenPreview.show(viewModel)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Watch the edited video full screen (Esc to come back)")
            .accessibilityLabel("Watch full screen")
        }
        .labelStyle(ControlLabelStyle(showsTitle: !compactControls))
        .controlSize(.small)
        .disabled(viewModel.isExporting || viewModel.isLoading)
        // At the editor's default size the names truncated to "S…" and
        // "A…"; icons alone, each with its tooltip, read better. The
        // width is what the named buttons need, measured from a render.
        .onGeometryChange(for: Bool.self) { $0.size.width < 730 } action: { compactControls = $0 }
    }

    // MARK: Helpers

    private var undoTooltip: String {
        let name = viewModel.undoActionName
        return name.isEmpty ? "Undo (⌘Z)" : "Undo \(name) (⌘Z)"
    }

    private var redoTooltip: String {
        let name = viewModel.redoActionName
        return name.isEmpty ? "Redo (⌘⇧Z)" : "Redo \(name) (⌘⇧Z)"
    }

    private func timeString(_ t: CMTime) -> String {
        TimelineMath.timeString(t)
    }

    private func xForTime(_ time: CMTime, width: CGFloat) -> CGFloat {
        TimelineMath.x(for: time, duration: viewModel.duration, width: width)
    }

    private func timeForX(_ x: CGFloat, width: CGFloat) -> CMTime {
        TimelineMath.time(atX: x, duration: viewModel.duration, width: width)
    }

    /// "1×", "1.25×".
    private static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }

    private func clampHandleOffset(_ x: CGFloat, width: CGFloat) -> CGFloat {
        max(0, min(width - handleWidth, x))
    }
}

/// The controls' buttons with their names, or icons alone when the bar
/// is short of room.
private struct ControlLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            Label(configuration)
                .labelStyle(.titleAndIcon)
        } else {
            configuration.icon
        }
    }
}

struct TrimHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 18)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}
