import AppKit
import SwiftUI

/// An error the way a person should read it: what happened and what to
/// do, in plain words. The technical text (an AVFoundation code, an HTTP
/// status) stays in `details`, behind Copy Details, for whoever fixes it.
/// Export and upload failures used to show it raw, e.g. "Final render
/// failed: reader.startReading: … (AVFoundationErrorDomain error -11841.)".
struct FriendlyError: Equatable {
    let title: String
    let advice: String
    let details: String

    init(title: String, advice: String, details: String) {
        self.title = title
        self.advice = advice
        self.details = details
    }

    init(_ error: Error) {
        let ns = error as NSError
        var details = error.localizedDescription
        if !(error is LocalizedError), !details.contains(ns.domain) {
            details += " (\(ns.domain) \(ns.code))"
        }
        self = Self.describe(error, details: details)
    }

    private static let passItOn = "If it keeps happening, use Copy Details to pass the error along."
    private static let outOfSpaceTitle = "Your Mac is out of space"

    var isOutOfSpace: Bool { title == Self.outOfSpaceTitle }

    private static func describe(_ error: Error, details: String) -> FriendlyError {
        if isOutOfSpace(error, details: details) {
            return FriendlyError(title: outOfSpaceTitle,
                                 advice: "Pepper couldn't save the video. Free up some space, then try again.",
                                 details: details)
        }
        switch error {
        case FinalRenderer.RenderError.cancelled:
            return FriendlyError(title: "Export cancelled", advice: "Nothing was saved.", details: details)
        case is FinalRenderer.RenderError:
            return FriendlyError(title: "Pepper couldn't make the video",
                                 advice: "Close the recording, open it again, and try once more. \(passItOn)",
                                 details: details)
        case let orbis as OrbisError:
            return describe(orbis, details: details)
        case let captions as CaptionTranscriber.TranscriberError:
            return describe(captions, details: details)
        case is URLError:
            return network(details)
        default:
            return FriendlyError(title: "Something went wrong", advice: "Try again. \(passItOn)", details: details)
        }
    }

    private static func describe(_ error: OrbisError, details: String) -> FriendlyError {
        switch error {
        case .networkError:
            return network(details)
        case .serverError(let status, _) where status >= 500:
            return FriendlyError(title: "Orbis had a problem",
                                 advice: "Orbis couldn't take the video just now. Try again in a few minutes.",
                                 details: details)
        case .serverError:
            return FriendlyError(title: "Orbis didn't accept the video", advice: "Try again. \(passItOn)", details: details)
        case .decodingError:
            return FriendlyError(title: "Orbis replied in a way Pepper didn't expect",
                                 advice: "Pepper may need updating: choose Pepper › Check for Updates…, then try again.",
                                 details: details)
        case .tokenMissing, .tokenInvalid, .oauthRejected, .signInFailed:
            return FriendlyError(title: "You're signed out of Orbis",
                                 advice: "Sign in again in Settings › Orbis, then try again.",
                                 details: details)
        case .permissionDenied, .tooLarge, .uploadURLExpired, .invalidHost:
            // These already say what to do.
            return FriendlyError(title: "Orbis didn't accept the video", advice: error.localizedDescription, details: details)
        }
    }

    private static func describe(_ error: CaptionTranscriber.TranscriberError, details: String) -> FriendlyError {
        switch error {
        case .unavailable:
            return FriendlyError(title: "This Mac can't write captions",
                                 advice: "macOS's on-device speech recognition isn't available here.",
                                 details: details)
        case .noSpeechDetected:
            return FriendlyError(title: "Pepper didn't hear any speech",
                                 advice: "If you did talk, check the waveform on the timeline: the microphone may have been muted or too quiet.",
                                 details: details)
        case .assetUnavailable:
            return FriendlyError(title: "Pepper couldn't get the speech model",
                                 advice: "Captions use macOS's speech model for your language, downloaded the first time. Check your internet connection, then try again.",
                                 details: details)
        case .recognizerFailed:
            return FriendlyError(title: "Pepper couldn't write captions", advice: "Try again. \(passItOn)", details: details)
        }
    }

    /// A recording the editor (or Send to Orbis) couldn't open. Whatever
    /// the cause, it's the recording's files, so say that rather than a
    /// generic "something went wrong".
    static func opening(_ error: Error) -> FriendlyError {
        FriendlyError(title: "Pepper couldn't open this recording",
                      advice: "Some of its files may be missing or damaged. Close it and open it again. \(passItOn)",
                      details: FriendlyError(error).details)
    }

    private static func network(_ details: String) -> FriendlyError {
        FriendlyError(title: "Pepper couldn't reach Orbis",
                      advice: "Check your internet connection, then try again.",
                      details: details)
    }

    /// Disk full, however it surfaces: Cocoa, POSIX, or AVFoundation's
    /// -11807 (often only in a render error's text).
    private static func isOutOfSpace(_ error: Error, details: String) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        return details.contains("-11807") || details.localizedCaseInsensitiveContains("no space left")
    }

    func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }
}

/// A failure in a sheet: what happened, what to do, and Copy Details.
/// `compact` sizes it for an inspector row.
struct FriendlyErrorView: View {
    let error: FriendlyError
    var compact = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(compact ? .system(size: 13) : .title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                Text(error.title).font(compact ? .system(size: 12.5, weight: .semibold) : .headline)
                Text(error.advice)
                    .font(compact ? .system(size: 11.5) : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Details Copied" : "Copy Details") {
                    error.copyDetails()
                    copied = true
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(error.details)
            }
            Spacer(minLength: 0)
        }
    }
}
