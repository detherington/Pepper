import AppKit
import SwiftUI
import AVFoundation

#if DEBUG
extension EditorWindowController {
    /// Review hook: `-pepper.debug.renderEditor <dir>
    /// -pepper.debug.renderEditorBundle <recording.pepper>` opens that
    /// recording and writes the window (toolbar and inspector included)
    /// as PNGs: every row closed, then each row open. Add
    /// `-pepper.debug.renderAppearance light|dark` to force one. True when
    /// it ran; the caller then quits. Debug builds only.
    static func renderIfRequested() -> Bool {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "pepper.debug.renderEditor"),
              let bundlePath = defaults.string(forKey: "pepper.debug.renderEditorBundle"),
              let project = try? RecordingProject.load(bundleURL: URL(fileURLWithPath: bundlePath)) else { return false }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = EditorWindowController(project: project)
        // `-pepper.debug.renderEditorSize <w>x<h>`: another size, e.g. the
        // editor's default 1040x680.
        let size = defaults.string(forKey: "pepper.debug.renderEditorSize")?
            .split(separator: "x").compactMap { Double($0) }
        controller.window?.setContentSize(size?.count == 2
            ? NSSize(width: size![0], height: size![1])
            : NSSize(width: 1280, height: 860))
        switch defaults.string(forKey: "pepper.debug.renderAppearance") {
        case "light": controller.window?.appearance = NSAppearance(named: .aqua)
        case "dark":  controller.window?.appearance = NSAppearance(named: .darkAqua)
        default:      break
        }
        controller.showWindow(nil)
        let vm = controller.viewModel
        let deadline = Date().addingTimeInterval(15)
        while vm.isLoading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let states: [InspectorFeature?] = [nil] + InspectorFeature.allCases
        for state in states {
            vm.openInspectorFeature = state
            vm.selectedZoomID = state == .zoom ? vm.zoomKeyframes.first?.id : nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            guard let frameView = controller.window?.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let name = state?.rawValue ?? "closed"
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("editor-\(name).png"))
        }
        // `-pepper.debug.renderEditorZoom <factor>`: the timeline zoomed
        // in, with the playhead moved to the middle of the recording (the
        // view should follow it there).
        let zoom = defaults.double(forKey: "pepper.debug.renderEditorZoom")
        if zoom > 1 {
            vm.openInspectorFeature = nil
            vm.setTimelineZoom(CGFloat(zoom))
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            vm.seek(to: CMTimeMultiplyByFloat64(vm.duration, multiplier: 0.5))
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            if let frameView = controller.window?.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("editor-zoomed.png"))
            }
        }
        // `-pepper.debug.renderExportTo <file.mp4>`: run the editor's own
        // export (its layout and trim, as Export and Send to Orbis do)
        // and log how it ended.
        if let exportPath = defaults.string(forKey: "pepper.debug.renderExportTo") {
            let url = URL(fileURLWithPath: exportPath)
            // `-pepper.debug.renderExportTrimIn <seconds>`: Set In at the
            // playhead first, as the timeline button does.
            let trimIn = defaults.double(forKey: "pepper.debug.renderExportTrimIn")
            if trimIn > 0 {
                vm.seek(to: CMTime(seconds: trimIn, preferredTimescale: 600))
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                vm.setTrimStartToCurrent()
                PepperDebug.log("DEBUG: Set In at playhead \(vm.currentTime.value)/\(vm.currentTime.timescale)")
            }
            // `-pepper.debug.renderExportTrimInNs <nanoseconds>`: an In point
            // in the player's nanosecond time base, as Set In gets during
            // playback.
            if let trimInNs = defaults.string(forKey: "pepper.debug.renderExportTrimInNs").flatMap(Int64.init) {
                vm.setTrimStart(CMTime(value: CMTimeValue(trimInNs), timescale: 1_000_000_000))
                PepperDebug.log("DEBUG: Set In at \(vm.trimStart.value)/\(vm.trimStart.timescale)")
            }
            // `-pepper.debug.renderExportCutNs <start,end>`: a cut between
            // two nanosecond marks.
            if let cut = defaults.string(forKey: "pepper.debug.renderExportCutNs")?
                .split(separator: ",").compactMap({ Int64($0) }), cut.count == 2 {
                vm.insertCut(CMTimeRange(start: CMTime(value: cut[0], timescale: 1_000_000_000),
                                         end: CMTime(value: cut[1], timescale: 1_000_000_000)))
                PepperDebug.log("DEBUG: cut \(vm.cutRanges.map { "\(CMTimeGetSeconds($0.start))..\(CMTimeGetSeconds($0.end))" })")
            }
            // `-pepper.debug.renderExportCleanAudio YES`: Clean up audio on.
            if defaults.bool(forKey: "pepper.debug.renderExportCleanAudio") {
                var style = vm.noiseReductionStyle
                style.enabled = true
                vm.noiseReductionStyle = style
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                let cleanDeadline = Date().addingTimeInterval(120)
                while vm.isCleaningMic || vm.isLoading, Date() < cleanDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            }
            vm.startExport(to: url)
            let exportDeadline = Date().addingTimeInterval(600)
            while vm.isExporting, Date() < exportDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            let outcome = vm.exportError.map { "FAILED: \($0.localizedDescription)" } ?? "OK"
            PepperDebug.log("DEBUG: export \(url.lastPathComponent) trim=\(CMTimeGetSeconds(vm.trimStart))..\(CMTimeGetSeconds(vm.trimEnd)) duration=\(CMTimeGetSeconds(vm.duration)) → \(outcome)")
            print("EXPORT \(outcome)")
            // The export sheet as it ended (an error shows there).
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if let sheetView = controller.window?.attachedSheet?.contentView?.superview,
               let rep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
                sheetView.cacheDisplay(in: sheetView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("editor-export-result.png"))
            }
        }
        // Quick polish writes zooms and captions into the bundle, so
        // this pass is opt-in: point it at a copy.
        if defaults.bool(forKey: "pepper.debug.renderPolish") {
            func snapshot(_ name: String) {
                guard let frameView = controller.window?.contentView?.superview,
                      let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("editor-\(name).png"))
            }
            vm.openInspectorFeature = nil
            vm.quickPolish()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            snapshot("polishing")
            let polishDeadline = Date().addingTimeInterval(90)
            while vm.isPolishing, Date() < polishDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            snapshot("polished")
        }
        PepperDebug.log("DEBUG: rendered editor to \(dir.path)")
        return true
    }
}
#endif
