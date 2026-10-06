import Foundation
import Testing
@testable import Pepper

/// Captions › Fix a word everywhere (`TranscriptionLog.replacingWord`).
struct CaptionReplaceTests {
    private func log(_ texts: String...) -> TranscriptionLog {
        TranscriptionLog(version: 1, locale: "en-US", createdAt: Date(), lines: texts.enumerated().map {
            TranscriptionLine(text: $1, startSeconds: Double($0), endSeconds: Double($0) + 1)
        })
    }

    @Test func fixesANameInEveryLineWhateverItsCase() {
        let (lines, count) = log("Open orbus and sign in", "Orbus shows the video", "No name here")
            .replacingWord("orbus", with: "Orbis")
        #expect(count == 2)
        #expect(lines.map(\.text) == ["Open Orbis and sign in", "Orbis shows the video", "No name here"])
    }

    @Test func onlyWholeWordsChange() {
        let (lines, count) = log("an answer and a plan, an idea").replacingWord("an", with: "one")
        #expect(count == 2)
        #expect(lines[0].text == "one answer and a plan, one idea")
    }

    @Test func handlesPhrasesAndPunctuation() {
        #expect(log("we use or bis daily").replacingWord("or bis", with: "Orbis").lines[0].text == "we use Orbis daily")
        #expect(log("written in c++, not c").replacingWord("C++", with: "Swift").lines[0].text == "written in Swift, not c")
    }

    @Test func theReplacementGoesInAsTyped() {
        #expect(log("costs ten dollars").replacingWord("ten dollars", with: "$10").lines[0].text == "costs $10")
    }

    @Test func nothingToFindChangesNothing() {
        let original = log("hello there")
        #expect(original.replacingWord("  ", with: "x").count == 0)
        #expect(original.replacingWord("bye", with: "x").lines == original.lines)
        #expect(original.occurrences(ofWord: "HELLO") == 1)
    }

    @Test func linesKeepTheirIdentityAndTiming() {
        let original = log("fix orbus")
        let fixed = original.replacingWord("orbus", with: "Orbis").lines[0]
        #expect(fixed.id == original.lines[0].id)
        #expect(fixed.startSeconds == original.lines[0].startSeconds)
    }
}
