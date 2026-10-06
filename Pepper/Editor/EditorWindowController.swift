import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let project: RecordingProject
    let viewModel: EditorViewModel
    var onClose: (() -> Void)?

    /// Where the last editor was, and its size, for the next one. Saved
    /// by hand rather than as an autosave name: two editors open at once
    /// can't share one.
    private static let frameName = "PepperEditor"

    /// `previous`: an editor already open, to cascade from instead of
    /// landing exactly on top of it.
    init(project: RecordingProject, cascadingFrom previous: NSWindow? = nil) {
        self.project = project
        self.viewModel = EditorViewModel(project: project)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // "Today, 12:59 PM" rather than the bundle's file name; also what
        // the Window menu lists.
        window.title = RecordingBundle.displayTitle(project.bundleURL)
        let host = NSHostingController(rootView: EditorView(viewModel: viewModel))
        // Lets EditorView's `.toolbar` (Export, Send to Orbis, details)
        // become this window's toolbar; an NSWindow hosting SwiftUI gets
        // no toolbar otherwise.
        host.sceneBridgingOptions = [.toolbars]
        window.contentViewController = host
        window.toolbarStyle = .unified
        window.center()
        window.setFrameUsingName(Self.frameName)
        if let previous {
            window.cascadeTopLeft(from: previous.cascadeTopLeft(from: .zero))
        }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        // Set after placing the window, so the cascade above isn't saved
        // as where the next editor should open.
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        // Edits autosave on a short debounce; don't lose one in flight.
        viewModel.flushPendingSaves()
        onClose?()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    // MARK: - Edit menu

    // Undo and Redo in the Edit menu, for the editor's own undo stack.
    // A custom action rather than `undo:`, which a focused text field
    // would take for its own typing: ⌘Z in the editor has always undone
    // editor changes, caption text included.

    @objc func undoEditorChange(_ sender: Any?) { viewModel.performUndo() }
    @objc func redoEditorChange(_ sender: Any?) { viewModel.performRedo() }

    // File › Export… and Send to Orbis…: the view owns the save panel and
    // the Orbis sheet, so the command is handed to it.
    @objc func exportVideo(_ sender: Any?) { viewModel.pendingMenuCommand = .export }
    @objc func sendToOrbis(_ sender: Any?) { viewModel.pendingMenuCommand = .sendToOrbis }
}

extension EditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoEditorChange(_:)):
            let name = viewModel.undoActionName
            item.title = viewModel.canUndo && !name.isEmpty ? "Undo \(name)" : "Undo"
            return viewModel.canUndo
        case #selector(redoEditorChange(_:)):
            let name = viewModel.redoActionName
            item.title = viewModel.canRedo && !name.isEmpty ? "Redo \(name)" : "Redo"
            return viewModel.canRedo
        case #selector(exportVideo(_:)):
            return viewModel.canStartExport
        case #selector(sendToOrbis(_:)):
            // The toolbar only shows Send to Orbis when signed in.
            return viewModel.canStartExport && OrbisAccount.shared.isConnected
        default:
            return true
        }
    }
}
