import SwiftUI

/// Captions row: write them from the narration, pick a size and height,
/// fix any line, and optionally save a subtitle file alongside the video.
struct CaptionsFeature: View {
    @Bindable var vm: EditorViewModel

    private static let sizes: [(String, Double)] = [("Small", 0.035), ("Medium", 0.045), ("Large", 0.06)]
    private static let heights: [(String, Double)] = [("Bottom", 0.06), ("Raised", 0.16)]

    /// Switching on with no captions yet writes them.
    static func isOn(_ vm: EditorViewModel) -> Binding<Bool> {
        Binding(
            get: { vm.isTranscribing || (vm.transcription != nil && vm.captionStyle.enabled) },
            set: { on in
                var s = vm.captionStyle
                s.enabled = on
                vm.captionStyle = s
                if on, vm.transcription == nil { vm.generateCaptions() }
            }
        )
    }

    static func status(_ vm: EditorViewModel) -> String {
        if vm.isTranscribing { return "Writing captions…" }
        guard let log = vm.transcription, vm.captionStyle.enabled else { return "Off" }
        return "\(log.lines.count) line\(log.lines.count == 1 ? "" : "s") from your narration"
    }

    var body: some View {
        if vm.isTranscribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Note("Writing captions from your narration…")
            }
        } else if let log = vm.transcription {
            FieldLabel("Size")
            ChoiceStrip(
                label: "Caption size",
                options: Self.sizes.map { (label: $0.0, value: $0.0) },
                selection: Binding(
                    get: { InspectorFormat.nearest(vm.captionStyle.fontSizeFraction, in: Self.sizes.map { ($0.0, $0.1) }) },
                    set: { name in
                        guard let preset = Self.sizes.first(where: { $0.0 == name }) else { return }
                        var s = vm.captionStyle; s.fontSizeFraction = preset.1; vm.captionStyle = s
                    }
                )
            )
            FieldLabel("Position")
            ChoiceStrip(
                label: "Caption position",
                options: Self.heights.map { (label: $0.0, value: $0.0) },
                selection: Binding(
                    get: { InspectorFormat.nearest(vm.captionStyle.bottomInsetFraction, in: Self.heights.map { ($0.0, $0.1) }) },
                    set: { name in
                        guard let preset = Self.heights.first(where: { $0.0 == name }) else { return }
                        var s = vm.captionStyle; s.bottomInsetFraction = preset.1; vm.captionStyle = s
                    }
                )
            )
            Note("Raised keeps them clear of a webcam in a bottom corner.")

            CaptionEditList(vm: vm, lines: log.lines)

            CaptionReplaceBox(vm: vm, log: log)

            Toggle("Also save a subtitle file", isOn: $vm.exportSRTSidecar)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
                .help("Saves an .srt file next to the exported video, for YouTube and video editors.")

            MoreOptions {
                HStack(spacing: 8) {
                    Button("Write them again") { vm.generateCaptions() }
                        .controlSize(.small)
                    Button("Remove captions", role: .destructive) { vm.clearCaptions() }
                        .controlSize(.small)
                }
                Note("Writing them again replaces any lines you've edited.")
            }
        } else {
            Note("Pepper writes captions from your narration, right on this Mac. You can fix any line afterwards.")
            Button {
                vm.generateCaptions()
            } label: {
                Text("Write captions").frame(maxWidth: .infinity)
            }
        }

        if let error = vm.transcriptionError {
            FriendlyErrorView(error: FriendlyError(error), compact: true)
        }
    }
}

/// Fix a word everywhere: the speech engine tends to mishear the same
/// name in every line ("Orbus" for Orbis), and fixing it line by line
/// in the edit list was the only way. Whole words only, any case (see
/// `TranscriptionLog.replacingWord`), one undo step.
private struct CaptionReplaceBox: View {
    let vm: EditorViewModel
    let log: TranscriptionLog
    @State private var find = ""
    @State private var replacement = ""
    @State private var replaced: Int?

    var body: some View {
        let found = log.occurrences(ofWord: find)
        let target = replacement.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Fix a word everywhere")
            HStack(spacing: 6) {
                TextField("Find", text: $find)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("Replace with", text: $replacement)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            HStack {
                Text(status(found: found))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Replace all") {
                    replaced = vm.replaceWordInCaptions(find, with: target)
                    find = ""
                    replacement = ""
                }
                .controlSize(.small)
                .disabled(found == 0 || target.isEmpty || target == find.trimmingCharacters(in: .whitespaces))
            }
        }
        .onChange(of: find) { _, new in if !new.isEmpty { replaced = nil } }
    }

    private func status(found: Int) -> String {
        if find.trimmingCharacters(in: .whitespaces).isEmpty {
            if let replaced { return "Replaced \(replaced) time\(replaced == 1 ? "" : "s")." }
            return "For a name the captions got wrong."
        }
        return found == 0 ? "Not in the captions" : "Found \(found) time\(found == 1 ? "" : "s")"
    }
}
