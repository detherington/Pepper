import SwiftUI
import AVFoundation
import AppKit

/// Clean up audio: the noise-reduced mic file and when it is regenerated.
extension EditorViewModel {
    // MARK: - Noise reduction

    /// URL of the cleaned mic file to feed into the composition, or
    /// nil to pass through the raw `mic.m4a`. Nil when noise reduction
    /// is disabled, or enabled-but-file-not-yet-generated (async
    /// generation is in flight).
    func effectiveMicOverrideURL() -> URL? {
        guard noiseReductionStyle.enabled else { return nil }
        let url = project.bundle.cleanedMicAudioURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Called from `noiseReductionStyle.didSet` when the user toggles
    /// or switches strength. Decides whether we need to regenerate the
    /// cleaned file + rebuild the composition.
    func handleNoiseReductionChange(previous: NoiseReductionStyle) {
        let cleanedURL = project.bundle.cleanedMicAudioURL
        let needsRegen: Bool = {
            // Strength change invalidates the existing cleaned file —
            // we don't stamp the strength into the file name, so we
            // regenerate whenever the recipe shifts.
            if noiseReductionStyle.enabled,
               previous.strength != noiseReductionStyle.strength {
                return true
            }
            // First time enabling on this recording — generate if
            // missing.
            if noiseReductionStyle.enabled,
               !FileManager.default.fileExists(atPath: cleanedURL.path) {
                return true
            }
            return false
        }()

        if needsRegen {
            generateCleanedMic()
        } else {
            // Toggle without regen — just swap the composition to
            // point at the (possibly now-inactive) cleaned file.
            Task { await self.rebuildComposition() }
        }
    }

    private func generateCleanedMic() {
        guard !isCleaningMic else { return }
        isCleaningMic = true
        let inputURL = project.bundle.micAudioURL
        let outputURL = project.bundle.cleanedMicAudioURL
        let settings = noiseReductionStyle.strength.cleanerSettings
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MicCleaner.clean(
                        inputURL: inputURL,
                        outputURL: outputURL,
                        settings: settings
                    )
                }.value
                PepperDebug.log("NR: cleaned mic written to \(outputURL.lastPathComponent)")
            } catch {
                PepperDebug.log("NR: cleaner failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                guard let self else { return }
                self.isCleaningMic = false
                Task { await self.rebuildComposition() }
            }
        }
    }
}
