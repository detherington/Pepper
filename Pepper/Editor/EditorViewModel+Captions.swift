import SwiftUI
import AVFoundation
import AppKit

/// Captions: writing them from the narration, and editing lines.
extension EditorViewModel {
    // MARK: - Captions

    /// Transcribe the mic track on-device via `CaptionTranscriber`,
    /// persist to `transcription.json`, and push into the compositor.
    /// Called by the inspector's "Write captions" button and Quick
    /// polish. Runs async and can take a while — `isTranscribing` drives
    /// the spinner; a failure populates `transcriptionError` for the UI
    /// to surface. `finish` gets the line count or the error, on the
    /// main actor.
    func generateCaptions(then finish: ((Result<Int, Error>) -> Void)? = nil) {
        guard !isTranscribing else { return }
        isTranscribing = true
        transcriptionError = nil
        let audioURL = project.bundle.micAudioURL
        Task { [weak self] in
            do {
                let log = try await CaptionTranscriber.transcribe(audioURL: audioURL)
                await MainActor.run {
                    guard let self else { return }
                    self.transcription = log
                    self.isTranscribing = false
                    self.saveNow(.transcription)
                    self.applyLayout()
                    finish?(.success(log.lines.count))
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isTranscribing = false
                    self.transcriptionError = error
                    PepperDebug.log("CAPTIONS: generate failed: \(error.localizedDescription)")
                    finish?(.failure(error))
                }
            }
        }
    }

    /// Remove the persisted transcription + clear the in-memory copy.
    /// Used by the inspector's "Clear" button.
    func clearCaptions() {
        transcription = nil
        try? FileManager.default.removeItem(at: project.bundle.transcriptionURL)
        applyLayout()
    }

    // MARK: - Caption line editing

    /// Replace the text of a single caption line. Writes the file back
    /// and registers an undo step keyed on the line id so multiple
    /// keystrokes within the coalesce window collapse into one entry
    /// (feels like a normal text-edit undo instead of one-per-keystroke).
    func updateCaptionLineText(id: UUID, to newText: String) {
        guard var log = transcription,
              let idx = log.lines.firstIndex(where: { $0.id == id }) else { return }
        let oldLine = log.lines[idx]
        guard oldLine.text != newText else { return }
        log.lines[idx].text = newText
        transcription = log
        persistTranscription()
        applyLayout()
        let capturedID = id
        registerUndoableSnapshot(
            "Edit Caption",
            coalesceKey: "caption-text-\(capturedID.uuidString)",
            capture: { vm -> String in
                vm.transcription?.lines.first(where: { $0.id == capturedID })?.text ?? ""
            },
            oldState: oldLine.text
        ) { vm, state in
            guard var log = vm.transcription,
                  let i = log.lines.firstIndex(where: { $0.id == capturedID }) else { return }
            log.lines[i].text = state
            vm.transcription = log
            vm.persistTranscription()
            vm.applyLayout()
        }
    }

    /// Adjust the start/end seconds of a caption line. Both values are
    /// clamped so start < end with a minimum 100ms length (anything
    /// shorter flashes too briefly to read).
    func updateCaptionLineTiming(id: UUID, start: TimeInterval, end: TimeInterval) {
        guard var log = transcription,
              let idx = log.lines.firstIndex(where: { $0.id == id }) else { return }
        let minLen: TimeInterval = 0.1
        let clampedStart = max(0, start)
        let clampedEnd = max(clampedStart + minLen, end)
        let oldLine = log.lines[idx]
        guard oldLine.startSeconds != clampedStart || oldLine.endSeconds != clampedEnd else { return }
        log.lines[idx].startSeconds = clampedStart
        log.lines[idx].endSeconds = clampedEnd
        transcription = log
        persistTranscription()
        applyLayout()
        let capturedID = id
        let oldPair = (oldLine.startSeconds, oldLine.endSeconds)
        registerUndoableSnapshot(
            "Adjust Caption Timing",
            coalesceKey: "caption-timing-\(capturedID.uuidString)",
            capture: { vm -> (TimeInterval, TimeInterval) in
                if let l = vm.transcription?.lines.first(where: { $0.id == capturedID }) {
                    return (l.startSeconds, l.endSeconds)
                }
                return (0, 0)
            },
            oldState: oldPair
        ) { vm, state in
            guard var log = vm.transcription,
                  let i = log.lines.firstIndex(where: { $0.id == capturedID }) else { return }
            log.lines[i].startSeconds = state.0
            log.lines[i].endSeconds = state.1
            vm.transcription = log
            vm.persistTranscription()
            vm.applyLayout()
        }
    }

    /// Remove a single caption line. Undoable; the full pre-delete
    /// `lines` array is snapshotted so restore preserves order.
    func deleteCaptionLine(id: UUID) {
        guard var log = transcription,
              let idx = log.lines.firstIndex(where: { $0.id == id }) else { return }
        let preDelete = log.lines
        log.lines.remove(at: idx)
        transcription = log
        persistTranscription()
        applyLayout()
        registerUndoableSnapshot(
            "Delete Caption",
            capture: { vm -> [TranscriptionLine] in vm.transcription?.lines ?? [] },
            oldState: preDelete
        ) { vm, state in
            guard var l = vm.transcription else { return }
            l.lines = state
            vm.transcription = l
            vm.persistTranscription()
            vm.applyLayout()
        }
    }

    private func persistTranscription() { scheduleSave(.transcription) }
}
