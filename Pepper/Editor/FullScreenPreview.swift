import AppKit
import AVKit

/// "Watch full screen" from the timeline: the editor's player on a
/// window of its own, in its own full-screen space, playing the edit as
/// viewers will see it (trim and cuts skipped, every overlay on). The
/// editor's preview has no controls of its own any more, AVPlayerView's
/// full-screen button included, so this replaces it.
///
/// It shares the editor's `AVPlayer` rather than a copy, so it starts
/// where the playhead is and the editor is left where it stopped. Space
/// plays and pauses, ← → step, a click plays or pauses, and Esc or a
/// double-click comes back.
@MainActor
final class FullScreenPreview: NSObject, NSWindowDelegate {
    private static var current: FullScreenPreview?

    private let viewModel: EditorViewModel
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private let hint = NSView()

    static func show(_ viewModel: EditorViewModel) {
        guard current == nil else { return }
        let preview = FullScreenPreview(viewModel: viewModel)
        current = preview
        preview.present()
    }

    private init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        window = NSWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Pepper Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self

        let surface = PreviewSurface()
        surface.onClick = { [weak self] count in
            if count >= 2 { self?.leave() } else { self?.togglePlayPause() }
        }
        surface.onKey = { [weak self] event in self?.handle(event) ?? false }

        playerView.player = viewModel.player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(playerView)

        let hintText = NSTextField(labelWithString: "Esc to come back  ·  Space to play or pause")
        hintText.font = .systemFont(ofSize: 13, weight: .medium)
        hintText.textColor = .white
        hintText.translatesAutoresizingMaskIntoConstraints = false
        hint.addSubview(hintText)
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hint.layer?.cornerRadius = 8
        hint.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(hint)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: surface.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            hint.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -48),
            hintText.centerXAnchor.constraint(equalTo: hint.centerXAnchor),
            hintText.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            hint.widthAnchor.constraint(equalTo: hintText.widthAnchor, constant: 32),
            hint.heightAnchor.constraint(equalTo: hintText.heightAnchor, constant: 16),
        ])
        window.contentView = surface
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        window.toggleFullScreen(nil)
    }

    /// Back to the editor: out of full screen, and the window closes
    /// once it is (`windowDidExitFullScreen`).
    private func leave() {
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.close()
        }
    }

    /// The pointer hides once playback starts, until it moves.
    private func togglePlayPause() {
        let starting = !viewModel.isPlaying
        viewModel.togglePlayPause()
        if starting { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: leave()                                                   // Esc
        case 49: togglePlayPause()                                         // Space
        case 123: shift ? viewModel.stepSecond(forward: false) : viewModel.stepFrame(forward: false)  // ←
        case 124: shift ? viewModel.stepSecond(forward: true) : viewModel.stepFrame(forward: true)    // →
        default: return false
        }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) {
        if !viewModel.isPlaying { togglePlayPause() }
        // Say how to get out, then get out of the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                self?.hint.animator().alphaValue = 0
            }
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        viewModel.pausePlayback()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.pausePlayback()
        // Let go of the editor's player; its own preview keeps showing it.
        playerView.player = nil
        Self.current = nil
    }
}

/// The window's content: takes every click and key itself, so the
/// player view underneath never sees them.
private final class PreviewSurface: NSView {
    var onClick: ((_ clickCount: Int) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
