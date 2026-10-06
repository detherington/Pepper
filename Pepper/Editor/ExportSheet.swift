import SwiftUI
import AppKit

/// Modal sheet shown over the editor window during export, with progress
/// bar + time left + cancel, then where the video went (or what failed).
struct ExportSheet: View {
    @Bindable var viewModel: EditorViewModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let err = viewModel.exportError {
                errorContent(err: err)
            } else if let url = viewModel.exportedURL {
                savedContent(url: url)
            } else {
                progressContent
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    @ViewBuilder
    private var progressContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporting your video")
                    .font(.headline)
                Text(timeLeft ?? "Getting started…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        ProgressView(value: viewModel.exportProgress)
            .progressViewStyle(.linear)

        HStack {
            Text("\(Int(viewModel.exportProgress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) {
                viewModel.cancelExport()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var timeLeft: String? {
        guard let started = viewModel.exportStartedAt else { return nil }
        return ExportTimeLeft.text(progress: Double(viewModel.exportProgress),
                                   elapsed: Date().timeIntervalSince(started))
    }

    /// Where the video went, instead of Finder jumping to the front.
    /// Copy puts the file itself on the clipboard, to paste into Slack,
    /// Mail or a folder.
    @ViewBuilder
    private func savedContent(url: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(Brand.emerald)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video saved")
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("In \(FileManager.default.displayName(atPath: url.deletingLastPathComponent().path))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }

        HStack {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                copied = true
            }
            .help("Copy the video, to paste into Slack, Mail or a folder")
            Spacer()
            Button("Done") {
                viewModel.exportedURL = nil
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func errorContent(err: any Error) -> some View {
        FriendlyErrorView(error: FriendlyError(err))
        HStack {
            Spacer()
            Button("Close") {
                viewModel.exportError = nil
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// "About 2 min left", from how far a render has got and how long that
/// took. Nil until there's enough to go on: the first few percent
/// include the reader and encoder starting up, and guessing from them
/// swings wildly.
enum ExportTimeLeft {
    static func text(progress: Double, elapsed: TimeInterval) -> String? {
        guard progress >= 0.05, progress < 1, elapsed >= 2 else { return nil }
        let left = elapsed * (1 - progress) / progress
        if left < 10 { return "Almost done" }
        let seconds = Int((left / 5).rounded()) * 5
        if seconds < 60 { return "About \(seconds) s left" }
        return "About \(max(1, Int((left / 60).rounded()))) min left"
    }
}

/// The Quality choice, shown in the Export save panel. It used to be a
/// picker at the bottom of the inspector, far from the button it
/// affected.
enum ExportOptionsAccessory {
    @MainActor
    static func make(viewModel vm: EditorViewModel) -> NSView {
        let host = NSHostingView(rootView: ExportOptionsView(vm: vm))
        host.frame.size = host.fittingSize
        return host
    }
}

private struct ExportOptionsView: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Quality", selection: $vm.exportQuality) {
                ForEach(ExportQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text(vm.exportQuality.sizeHint)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
    }
}
