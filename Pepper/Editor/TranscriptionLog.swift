import Foundation

/// One displayable subtitle line — a run of words that belong on screen
/// at the same time. `SpeechAnalyzer` returns its results already grouped
/// this way, each with its own time range.
struct TranscriptionLine: Identifiable, Codable, Equatable, Sendable {
    /// Stable identifier for SwiftUI list + edit tracking. Persisted so
    /// IDs survive disk round-trips and undo snapshots compare cleanly.
    /// Older on-disk transcriptions without an `id` field get a fresh
    /// UUID at decode time (see `init(from:)` below).
    let id: UUID
    var text: String
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        text: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval
    ) {
        self.id = id
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, startSeconds, endSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.startSeconds = try c.decode(TimeInterval.self, forKey: .startSeconds)
        self.endSeconds = try c.decode(TimeInterval.self, forKey: .endSeconds)
    }
}

/// Persisted subtitle track for a recording — written by
/// `CaptionTranscriber` when the user hits "Generate captions" and read
/// by the editor + compositor to render burned-in subtitles.
///
/// Stored as `transcription.json` in the `.pepper` sidecar. Re-running
/// generation overwrites the file. Editing keeps the same file in place
/// with updated `lines`.
struct TranscriptionLog: Codable, Equatable, Sendable {
    let version: Int
    let locale: String
    let createdAt: Date
    var lines: [TranscriptionLine]

    static let empty = TranscriptionLog(version: 1, locale: "en-US", createdAt: Date(), lines: [])
}

// MARK: - Replace all

extension TranscriptionLog {
    /// The lines with every whole-word `find` replaced by `replacement`,
    /// and how many were. For the name the speech engine gets wrong in
    /// every line ("Orbus" for Orbis): case doesn't matter, and a match
    /// has to stand alone, so fixing "an" leaves "and" and "plan" be.
    /// `find` can be several words; the replacement goes in as typed.
    func replacingWord(_ find: String, with replacement: String) -> (lines: [TranscriptionLine], count: Int) {
        guard let regex = Self.wordPattern(find) else { return (lines, 0) }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        var total = 0
        let replaced = lines.map { line -> TranscriptionLine in
            let range = NSRange(line.text.startIndex..., in: line.text)
            let n = regex.numberOfMatches(in: line.text, range: range)
            guard n > 0 else { return line }
            total += n
            var next = line
            next.text = regex.stringByReplacingMatches(in: line.text, range: range, withTemplate: template)
            return next
        }
        return (replaced, total)
    }

    /// How many times `find` appears as a whole word, for the count
    /// shown while it's typed.
    func occurrences(ofWord find: String) -> Int {
        guard let regex = Self.wordPattern(find) else { return 0 }
        return lines.reduce(0) { $0 + regex.numberOfMatches(in: $1.text, range: NSRange($1.text.startIndex..., in: $1.text)) }
    }

    /// Not `\b`: that needs a letter at each end, and a name like "C++"
    /// ends in punctuation. Here a match just can't touch another
    /// letter or digit.
    private static func wordPattern(_ find: String) -> NSRegularExpression? {
        let word = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
