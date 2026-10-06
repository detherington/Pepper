import Foundation
import Testing
@testable import Pepper

/// Recording names: dates read from the bundle name, renames that keep a
/// recording's two files together (`RecordingBundle`).
struct RecordingBundleTests {
    @Test func theRecordedTimeComesFromTheName() throws {
        let date = try #require(RecordingBundle.recordedDate(URL(fileURLWithPath: "/tmp/Pepper_2026-10-02_12-59-36.pepper")))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second] == [2026, 10, 2, 12, 59, 36])
    }

    @Test func aRenamedRecordingShowsItsName() {
        #expect(RecordingBundle.recordedDate(URL(fileURLWithPath: "/tmp/Demo walkthrough.pepper")) == nil)
        #expect(RecordingBundle.displayTitle(URL(fileURLWithPath: "/tmp/Demo walkthrough.pepper")) == "Demo walkthrough")
    }

    @Test func namesAreMadeSafeForFiles() {
        #expect(RecordingBundle.fileSafeName("  ../a/b: c ") == "-a-b- c")
        #expect(RecordingBundle.fileSafeName("   ").isEmpty)
    }

    @Test func renamingMovesTheVideoAndAvoidsATakenName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Pepper_2026-10-02_12-59-36.pepper", isDirectory: true)
        try fm.createDirectory(at: original, withIntermediateDirectories: false)
        try Data("mp4".utf8).write(to: folder.appendingPathComponent("Pepper_2026-10-02_12-59-36.mp4"))
        try fm.createDirectory(at: folder.appendingPathComponent("Demo.pepper"), withIntermediateDirectories: false)

        let renamed = try RecordingBundle.rename(original, to: "Demo")

        #expect(renamed.lastPathComponent == "Demo 2.pepper")
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("Demo 2.mp4").path))
        #expect(!fm.fileExists(atPath: original.path))
        #expect(try RecordingBundle.rename(renamed, to: "Demo 2") == renamed)
    }
}
