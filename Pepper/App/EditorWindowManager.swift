import AppKit
import UniformTypeIdentifiers

/// Owns the open editor windows and the activation-policy flip that goes
/// with them: the app shows in the Dock (`.regular`) while any editor is
/// open — so windows can take focus — and drops back to menu-bar-only
/// (`.accessory`) when the last one closes.
@MainActor
final class EditorWindowManager {
    private(set) var windows: [EditorWindowController] = []
    private let showError: (String) -> Void

    init(showError: @escaping (String) -> Void) {
        self.showError = showError
    }

    /// Send to Orbis windows opened from the main window, for recordings
    /// not open in an editor.
    private var orbisSends: [OrbisSendWindowController] = []

    /// A local export or Orbis upload is running in these: editors' and
    /// the main window's Send to Orbis windows'. Quit waits for them.
    var exportingViewModels: [EditorViewModel] {
        (windows.map(\.viewModel) + orbisSends.map(\.viewModel)).filter(\.hasActiveExport)
    }

    /// Main window › Send to Orbis…. An open editor shows its own form;
    /// otherwise the recording loads with its saved edits behind a Send
    /// to Orbis window, without the editor.
    func sendToOrbis(_ url: URL) {
        if let editor = editor(for: url) {
            NSApp.activate(ignoringOtherApps: true)
            editor.window?.makeKeyAndOrderFront(nil)
            editor.viewModel.pendingMenuCommand = .sendToOrbis
            return
        }
        if let existing = orbisSend(for: url) {
            existing.show()
            return
        }
        do {
            let send = OrbisSendWindowController(project: try RecordingProject.load(bundleURL: url))
            DockPresence.claim(send)
            send.onClose = { [weak self, weak send] in
                guard let self, let send else { return }
                self.orbisSends.removeAll { $0 === send }
                DockPresence.release(send)
            }
            orbisSends.append(send)
            send.show()
        } catch {
            showError("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func orbisSend(for url: URL) -> OrbisSendWindowController? {
        orbisSends.first { $0.bundleURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// An editor has this recording open.
    func isOpen(_ url: URL) -> Bool {
        editor(for: url) != nil
    }

    /// This recording is being exported or uploaded, from its editor or a
    /// Send to Orbis window.
    func isExporting(_ url: URL) -> Bool {
        (editor(for: url)?.viewModel.hasActiveExport ?? false)
            || (orbisSend(for: url)?.viewModel.hasActiveExport ?? false)
    }

    /// Close this recording's editor (its edits are saved first) and any
    /// idle Send to Orbis window for it.
    func close(_ url: URL) {
        editor(for: url)?.close()
        orbisSend(for: url)?.close()
    }

    private func editor(for url: URL) -> EditorWindowController? {
        windows.first { $0.project.bundleURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// Editors left open at quit never get `windowWillClose`.
    func flushPendingSaves() {
        for editor in windows { editor.viewModel.flushPendingSaves() }
    }

    func open(_ url: URL) {
        guard RecordingBundle.isRecording(url) else {
            showError("\(url.lastPathComponent) isn't a Pepper recording.")
            return
        }

        // If already open, bring that window to front instead of duplicating.
        if let existing = editor(for: url) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        do {
            let project = try RecordingProject.load(bundleURL: url)
            // Editors are windowed — the app needs the Dock and focus
            // while one is open.
            let controller = EditorWindowController(project: project, cascadingFrom: windows.last?.window)
            DockPresence.claim(controller)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.windows.removeAll { $0 === controller }
                DockPresence.release(controller)
            }
            windows.append(controller)
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            showError("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = CaptureCoordinator.outputDirectory
        if let recordingType = UTType("com.darrell.pepper.recording") {
            panel.allowedContentTypes = [recordingType]
        }
        // The panel needs focus too. Opening a recording claims the Dock
        // for its editor before the panel lets go.
        DockPresence.claim(panel)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            open(url)
        }
        DockPresence.release(panel)
    }

    func openLatestRecording() {
        guard let latest = latestRecordingBundle() else {
            showError("No recordings found yet. Record something first.")
            return
        }
        open(latest)
    }

    /// The most recently *recorded* bundle, by creation date. Sorting by
    /// modification date picked whichever recording was edited last,
    /// since every editor save touches the bundle directory.
    private func latestRecordingBundle() -> URL? {
        let bundles = ((try? FileManager.default.contentsOfDirectory(
            at: CaptureCoordinator.outputDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter(RecordingBundle.isRecording)
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return bundles.max { created($0) < created($1) }
    }
}
