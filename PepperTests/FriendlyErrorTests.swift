import Foundation
import Testing
@testable import Pepper

/// What people read when an export or upload fails (`FriendlyError`).
struct FriendlyErrorTests {
    @Test func aFailedRenderReadsPlainlyAndKeepsTheDetails() {
        let error = FriendlyError(FinalRenderer.RenderError.exportFailed(
            "reader.startReading: The operation couldn't be completed. (AVFoundationErrorDomain error -11841.)"))
        #expect(error.title == "Pepper couldn't make the video")
        #expect(error.details.contains("-11841"))
        #expect(!error.isOutOfSpace)
    }

    @Test func aFullDiskIsCalledOut() {
        #expect(FriendlyError(FinalRenderer.RenderError.exportFailed("… (AVFoundationErrorDomain error -11807.)")).isOutOfSpace)
        #expect(FriendlyError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)).isOutOfSpace)
        #expect(FriendlyError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).isOutOfSpace)
    }

    @Test func offlineSaysSo() {
        #expect(FriendlyError(OrbisError.networkError(URLError(.notConnectedToInternet))).title == "Pepper couldn't reach Orbis")
        #expect(FriendlyError(URLError(.timedOut)).title == "Pepper couldn't reach Orbis")
    }

    @Test func orbisServerTroubleIsTold() {
        #expect(FriendlyError(OrbisError.serverError(status: 503, body: nil)).title == "Orbis had a problem")
        #expect(FriendlyError(OrbisError.serverError(status: 400, body: "bad")).title == "Orbis didn't accept the video")
    }

    @Test func anExpiredSignInAsksForANewOne() {
        let error = FriendlyError(OrbisError.tokenInvalid)
        #expect(error.title == "You're signed out of Orbis")
        #expect(error.advice.contains("Sign in again"))
    }

    @Test func cancellingIsNotAnError() {
        #expect(FriendlyError(FinalRenderer.RenderError.cancelled).title == "Export cancelled")
    }
}

extension FriendlyErrorTests {
    @Test func captionFailuresReadPlainly() {
        #expect(FriendlyError(CaptionTranscriber.TranscriberError.noSpeechDetected).title == "Pepper didn't hear any speech")
        let failed = FriendlyError(CaptionTranscriber.TranscriberError.recognizerFailed("SFSpeechErrorDomain 1101"))
        #expect(failed.title == "Pepper couldn't write captions")
        #expect(failed.details.contains("1101"))
    }

    @Test func aRecordingThatWontOpenSaysSo() {
        let error = FriendlyError.opening(EditorComposition.Error.missingScreenTrack)
        #expect(error.title == "Pepper couldn't open this recording")
        #expect(error.details.contains("screen.mov"))
    }
}
