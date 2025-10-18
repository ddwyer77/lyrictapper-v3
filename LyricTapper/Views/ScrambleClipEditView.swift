import SwiftUI

struct ScrambleClipEditView: View {
    @ObservedObject var app: AppState
    @State private var nudgeFrames: Int = 0

    private var takeIndex: Int? {
        guard let id = app.projectV2.tracks.scramble.currentTakeId else { return nil }
        return app.projectV2.tracks.scramble.takes.firstIndex(where: { $0.id == id })
    }
    private var take: TrackScrambleTake? {
        guard let idx = takeIndex else { return nil }
        return app.projectV2.tracks.scramble.takes[idx]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Stepper("Nudge (frames @30fps): \(nudgeFrames)", value: $nudgeFrames, in: -150...150, step: 1)
                Button("Apply Nudge Start") { applyNudge(startDelta: framesToSeconds(nudgeFrames), endDelta: 0) }
                Button("Apply Nudge End") { applyNudge(startDelta: 0, endDelta: framesToSeconds(nudgeFrames)) }
                Spacer()
                Button("Continue to Export") { app.stage = .scrambleExport }
            }
            Table(rows()) {
                TableColumn("#") { row in Text(String(row.index + 1)) }
                TableColumn("Video") { row in Text(row.videoName) }
                TableColumn("StartSec") { row in Text(String(format: "%.3f", row.startSec)) }
                TableColumn("Start") { row in Text(String(format: "%.3f", row.interval.start)) }
                TableColumn("End") { row in Text(String(format: "%.3f", row.interval.end)) }
            }
            .frame(minHeight: 240)
        }
        .padding()
    }

    private func rows() -> [Row] {
        guard let t = take else { return [] }
        var out: [Row] = []
        for i in 0..<min(t.intervals.count, t.cuts.count) {
            let iv = t.intervals[i]
            let cut = t.cuts[i]
            let name = t.videoCatalog[cut.videoID]?.filename ?? "?"
            out.append(Row(index: i, videoName: name, startSec: cut.startSec, interval: iv))
        }
        return out
    }

    private struct Row: Identifiable { let id = UUID(); let index: Int; let videoName: String; let startSec: Double; let interval: VideoInterval }

    private func framesToSeconds(_ frames: Int) -> Double { Double(frames) / 30.0 }

    private func applyNudge(startDelta: Double, endDelta: Double) {
        guard var t = take, let idx = takeIndex else { return }
        var updated: [VideoInterval] = []
        var lastEnd = 0.0
        for var it in t.intervals {
            it.start = max(0.0, it.start + startDelta)
            it.end = max(it.start, it.end + endDelta)
            it.start = max(it.start, lastEnd)
            lastEnd = it.end
            updated.append(it)
        }
        t.intervals = updated
        // Re-plan cuts with same seed to keep determinism
        let videos = t.videoCatalog.map { ($0.key, $0.value) }
        t.cuts = ScramblePlannerService.planCuts(intervals: t.intervals, videos: videos, seed: t.shuffleSeed, avoidanceSec: t.avoidanceWindowSec)
        app.projectV2.tracks.scramble.takes[idx] = t
    }
}


