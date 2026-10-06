import AppKit
import SwiftUI

/// Send to Orbis for a recording that isn't open in the editor, from the
/// main window's right-click menu. It loads the recording the way the
/// editor does (saved trim, cuts, captions and look) without showing the
/// editor, then shows the same Send to Orbis form in a window of its own.
///
/// The window has no close button: like the sheet in the editor, it ends
/// through the form's own Cancel, Done or Close, so an upload can't be
/// abandoned by closing it. Quitting mid-upload is handled with the
/// editors' exports (`EditorWindowManager.exportingViewModels`).
@MainActor
final class OrbisSendWindowController: NSObject, NSWindowDelegate {
    let viewModel: EditorViewModel
    var onClose: (() -> Void)?
    private var window: NSWindow?

    var bundleURL: URL { viewModel.project.bundleURL }

    init(project: RecordingProject) {
        viewModel = EditorViewModel(project: project)
    }

    func show() {
        let win = window ?? makeWindow()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: OrbisSendView(vm: viewModel) { [weak self] in self?.close() })
        // The window follows the form's size as it moves from loading to
        // the form to the result.
        host.sizingOptions = [.preferredContentSize]
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled]
        win.title = "Send to Orbis: \(RecordingBundle.displayTitle(bundleURL))"
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.delegate = self
        win.center()
        return win
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private struct OrbisSendView: View {
    let vm: EditorViewModel
    let close: () -> Void

    var body: some View {
        if let error = vm.loadError {
            VStack(alignment: .leading, spacing: 12) {
                FriendlyErrorView(error: FriendlyError(error))
                HStack {
                    Spacer()
                    Button("Close", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 520)
        } else if vm.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Opening the recording…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close)
            }
            .padding()
            .frame(width: 520)
        } else {
            OrbisExportSheet(vm: vm, onClose: close)
        }
    }
}

#if DEBUG
extension OrbisSendWindowController {
    /// Review hook: `-pepper.debug.renderOrbisSend <dir>
    /// -pepper.debug.renderOrbisSendBundle <recording.pepper>` opens the
    /// window for that recording and writes it as a PNG once the form is
    /// up. Nothing is sent. True when it ran; the caller then quits.
    static func renderIfRequested() -> Bool {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "pepper.debug.renderOrbisSend"),
              let bundlePath = defaults.string(forKey: "pepper.debug.renderOrbisSendBundle"),
              let project = try? RecordingProject.load(bundleURL: URL(fileURLWithPath: bundlePath)) else { return false }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = OrbisSendWindowController(project: project)
        controller.show()
        let deadline = Date().addingTimeInterval(20)
        while controller.viewModel.isLoading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        if let frameView = controller.window?.contentView?.superview,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("orbis-send.png"))
        }
        return true
    }
}
#endif
