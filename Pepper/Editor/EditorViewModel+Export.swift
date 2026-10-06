import SwiftUI
import AVFoundation
import AppKit

/// Export and Send to Orbis: the layout and trim a render uses, and the
/// export task.
extension EditorViewModel {
    // MARK: - Export

    /// Suggested default filename for the save panel.
    var suggestedExportFilename: String {
        let trimmed = !(trimStart == .zero && trimEnd == duration)
        return trimmed
            ? "\(project.displayName)_edited-trim.mp4"
            : "\(project.displayName)_edited.mp4"
    }

    /// Suggested starting directory for the save panel — same folder the
    /// original bundle lives in.
    var suggestedExportDirectory: URL {
        project.bundleURL.deletingLastPathComponent()
    }

    /// Build the `ExportLayout` that reflects the editor's current
    /// inspector values. Shared between the local-file export path
    /// and third-party destinations (Orbis) so both encode exactly
    /// what the user sees in the preview.
    /// The overlay as the editor currently has it — the single source
    /// for both the live preview (`applyLayout`) and exports
    /// (`currentExportLayout`), so the two can't drift apart.
    func currentOverlay() -> OverlaySettings {
        OverlaySettings(
            position: webcamPosition,
            shape: webcamShape,
            diameter: webcamDiameter,
            inset: webcamInset,
            webcamCustomOrigin: webcamCustomOrigin,
            webcamTransitions: webcamTransitions,
            webcamBackgroundStyle: webcamBackgroundStyle,
            zoomKeyframes: zoomEnabled ? zoomKeyframes : [],
            talkingHeadKeyframes: talkingHeadKeyframes,
            startCard: startCard,
            endCard: endCard,
            cursorRipples: cursorRipplesEnabled ? cursorRipples : [],
            cursorRippleStyle: .default,
            transcriptionLines: transcription?.lines ?? [],
            captionStyle: captionStyle,
            keystrokeChips: keystrokeOverlayStyle.enabled ? keystrokeChips : [],
            keystrokeOverlayStyle: keystrokeOverlayStyle,
            cursorTrack: cursorHighlightStyle.enabled ? cursorTrack : .empty,
            cursorHighlightStyle: cursorHighlightStyle
        )
    }

    func currentExportLayout() -> FinalRenderer.ExportLayout {
        FinalRenderer.ExportLayout(
            overlay: currentOverlay(),
            videoBitrate: exportQuality.bitrate,
            audioMixVolumes: audioMixVolumes,
            micOverrideURL: effectiveMicOverrideURL(),
            writeSRTSidecar: exportSRTSidecar
        )
    }

    /// Current editor trim range as a `TrimMap`, returning nil when
    /// the trim is trivial (no-op). Matches what `startExport` feeds
    /// to `FinalRenderer.render`.
    func currentExportTrimMap() -> TrimMap? {
        trimMap.isTrivial(fullDuration: duration) ? nil : trimMap
    }

    /// Kick off an async export with the editor's current inspector values
    /// and trim range. Does nothing if an export is already in flight.
    func startExport(to outputURL: URL) {
        guard !isExporting else { return }

        // Pause preview — the player item + the renderer both read the
        // same raw source files; pausing avoids resource contention.
        player.pause()

        let layout = currentExportLayout()
        let bundle = project.bundle
        let metadata = project.metadata
        let exportMap: TrimMap? = currentExportTrimMap()

        isExporting = true
        exportProgress = 0
        exportError = nil
        exportedURL = nil
        exportStartedAt = Date()

        exportTask = Task { [weak self] in
            do {
                let url = try await FinalRenderer.render(
                    bundle: bundle,
                    metadata: metadata,
                    layout: layout,
                    trimMap: exportMap,
                    outputURL: outputURL
                ) { fraction in
                    Task { @MainActor in
                        self?.exportProgress = fraction
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.isExporting = false
                    self.exportProgress = 1.0
                    // The sheet says where it went, with Show in Finder.
                    // Finder used to jump to the front instead.
                    self.exportedURL = url
                    self.applyLayout()
                }
            } catch is CancellationError {
                await self?.finishExport(error: FinalRenderer.RenderError.cancelled)
            } catch {
                await self?.finishExport(error: error)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// File-menu commands the view carries out: it owns the save panel
    /// and the Orbis sheet. Cleared once taken.
    enum MenuCommand { case export, sendToOrbis }

    /// Export and Send to Orbis can start (the toolbar buttons' rule).
    var canStartExport: Bool {
        !isExporting && exportedURL == nil && !isLoading && loadError == nil && !(activeOrbisExport?.isActive ?? false)
    }

    /// Local export or Orbis render/upload currently running.
    var hasActiveExport: Bool {
        isExporting || (activeOrbisExport?.isActive ?? false)
    }

    /// Cancel every export this editor started and wait for them to
    /// unwind (the renderer deletes its partial MP4 on cancel).
    func cancelActiveExportsAndWait() async {
        let running = exportTask
        running?.cancel()
        await activeOrbisExport?.cancelAndWait()
        await running?.value
    }

    private func finishExport(error: any Error) async {
        await MainActor.run {
            self.isExporting = false
            self.exportError = error
            self.exportProgress = 0
            self.applyLayout()
        }
    }
}
