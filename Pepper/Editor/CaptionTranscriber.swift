import AVFoundation
import Foundation
import Speech

/// Post-capture speech-to-text for the mic track, on this Mac:
/// `SpeechAnalyzer` driving a `Speech.SpeechTranscriber` module, the
/// framework Dictation itself uses. `AssetInventory` installs the model
/// for the locale first if it isn't already. It needs no Speech
/// Recognition permission (checked on macOS 27: it transcribes with that
/// permission never asked for), so captions never raise a system prompt.
///
/// Pepper needs macOS 26, so this is the only path. The older
/// `SFSpeechRecognizer` path, its permission and its Apple-servers
/// fallback went with macOS 14 and 15.
///
/// The type is named `CaptionTranscriber` (not `SpeechTranscriber`)
/// deliberately: Apple's API has a class named `Speech.SpeechTranscriber`
/// and a collision here would shadow it.
enum CaptionTranscriber {
    enum TranscriberError: Error, LocalizedError {
        /// This Mac can't run the on-device transcriber.
        case unavailable
        case recognizerFailed(String)
        case noSpeechDetected
        /// The speech model for this language isn't installed and couldn't
        /// be downloaded (a first download needs the network), or the
        /// language isn't supported at all.
        case assetUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This Mac can't write captions: macOS's on-device speech recognition isn't available here."
            case .recognizerFailed(let reason):
                return "Transcription failed: \(reason)"
            case .noSpeechDetected:
                return "Pepper didn't hear any speech in this recording. If you did talk, check the waveform on the timeline: the microphone may have been muted or too quiet."
            case .assetUnavailable(let reason):
                return "The speech model for this language isn't installed and couldn't be downloaded: \(reason)"
            }
        }
    }

    static func transcribe(audioURL: URL) async throws -> TranscriptionLog {
        guard Speech.SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        let preferred = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        PepperDebug.log("CAPTIONS: preferredLocale=\(preferred.identifier) systemLocale=\(Locale.current.identifier)")

        // The system's language, then en-US if its model can't be had.
        var lastError: Error = TranscriberError.noSpeechDetected
        for locale in dedup([preferred, Locale(identifier: "en-US")]) {
            do {
                return try await transcribe(audioURL: audioURL, locale: locale)
            } catch TranscriberError.noSpeechDetected {
                // The model ran and heard nothing; another language won't
                // hear more.
                PepperDebug.log("CAPTIONS: no speech for \(locale.identifier)")
                throw TranscriberError.noSpeechDetected
            } catch {
                PepperDebug.log("CAPTIONS: failed on \(locale.identifier): \(error.localizedDescription) — trying next")
                lastError = error
            }
        }
        throw lastError
    }

    private static func transcribe(audioURL: URL, locale: Locale) async throws -> TranscriptionLog {
        // `timeIndexedTranscriptionWithAlternatives` preset: emits
        // finalized results with `CMTimeRange` per result (exactly what
        // our line grouping wants) plus an alternatives list we ignore.
        let transcriber = Speech.SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        // Ensure the locale's model is installed. On first use, this
        // kicks off a download (can take a minute on a slow network).
        let status = await AssetInventory.status(forModules: [transcriber])
        PepperDebug.log("CAPTIONS: asset status for \(locale.identifier) = \(status)")
        switch status {
        case .unsupported:
            throw TranscriberError.assetUnavailable("\(locale.identifier) not supported")
        case .supported, .downloading:
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    PepperDebug.log("CAPTIONS: installing asset for \(locale.identifier)…")
                    try await req.downloadAndInstall()
                    PepperDebug.log("CAPTIONS: asset installed for \(locale.identifier)")
                }
            } catch {
                throw TranscriberError.assetUnavailable(error.localizedDescription)
            }
        case .installed:
            break
        @unknown default:
            break
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriberError.recognizerFailed("can't open \(audioURL.lastPathComponent): \(error.localizedDescription)")
        }

        // Creating the analyzer with a file + `finishAfterFile: true`
        // auto-starts analysis and closes the results stream when the
        // file is fully consumed. That makes iteration a simple
        // `for try await`.
        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                finishAfterFile: true
            )
        } catch {
            throw TranscriberError.recognizerFailed("SpeechAnalyzer init: \(error.localizedDescription)")
        }
        _ = analyzer  // keep the actor alive for the duration of the stream

        var lines: [TranscriptionLine] = []
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(result.range.end)
                guard !text.isEmpty, end > start else { continue }
                lines.append(TranscriptionLine(text: text, startSeconds: start, endSeconds: end))
            }
        } catch {
            throw TranscriberError.recognizerFailed("SpeechAnalyzer stream: \(error.localizedDescription)")
        }

        PepperDebug.log("CAPTIONS: produced \(lines.count) lines for \(locale.identifier)")
        guard !lines.isEmpty else {
            throw TranscriberError.noSpeechDetected
        }
        return TranscriptionLog(
            version: 1,
            locale: locale.identifier,
            createdAt: Date(),
            lines: lines
        )
    }

    private static func dedup(_ locales: [Locale]) -> [Locale] {
        var seen = Set<String>()
        return locales.filter { seen.insert($0.identifier).inserted }
    }
}
