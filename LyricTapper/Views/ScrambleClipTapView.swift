import SwiftUI
import AVFoundation

struct ScrambleClipTapView: View {
    @ObservedObject var app: AppState
    @StateObject var audio = AudioService()
    @State private var status: String = ""
    @State private var currentIntervalIndex: Int = 0

    private var currentTakeIndex: Int? {
        guard let id = app.projectV2.tracks.scramble.currentTakeId else { return nil }
        return app.projectV2.tracks.scramble.takes.firstIndex(where: { $0.id == id })
    }

    private var currentTake: TrackScrambleTake? {
        guard let idx = currentTakeIndex else { return nil }
        return app.projectV2.tracks.scramble.takes[idx]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyCaptureView {
                // Space pressed
                if audio.isPlaying {
                    let t = audio.currentTimeSeconds()
                    appendTap(t)
                    currentIntervalIndex += 1
                } else { try? audio.toggle() }
            } onRestart: {
                audio.resetToStart()
                clearTaps()
                currentIntervalIndex = 0
            } onFinish: {
                commitTake()
                app.stage = .scrambleEdit
            }
            .background(Color.clear)
            .allowsHitTesting(false)

            HStack(spacing: 12) {
                Button(audio.isPlaying ? "Pause" : "Play") {
                    Task { @MainActor in
                        do {
                            if audio.isPlaying { audio.pause() }
                            else {
                                if audio.duration <= 0, let data = app.project.audioPathBookmark, let url = BookmarkService.resolveBookmark(data) {
                                    try? audio.loadFile(url: url)
                                    app.setAudioDuration(seconds: audio.duration)
                                }
                                try? audio.prepareEngineIfNeeded(); try audio.play()
                            }
                        }
                    }
                }
                Button("Restart Take (R)") {
                    Task { @MainActor in
                        audio.resetToStart(); clearTaps(); currentIntervalIndex = 0; if audio.isPlaying { try? audio.play(from: 0) }
                    }
                }
                Spacer()
                Button("Commit as Take & Continue to Edit") { commitTake(); app.stage = .scrambleEdit }
            }
            .padding(.top, 8)

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                VStack(spacing: 6) {
                    Text("ScrambleClip Preview")
                        .foregroundColor(.white)
                    Text(currentPreviewLabel())
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(width: 220, height: 391)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))

            if !app.waveform.isEmpty {
                WaveformScrubView(app: app, audio: audio)
                    .frame(height: 160)
                    .padding(.vertical, 8)
            }
            Text(status).foregroundColor(.secondary)
        }
        .padding()
        .onAppear { prepareAudio() }
    }

    private func prepareAudio() {
        if let data = app.project.audioPathBookmark, let url = BookmarkService.resolveBookmark(data), url.startAccessingSecurityScopedResource() {
            do {
                try audio.loadFile(url: url)
                app.setAudioDuration(seconds: audio.duration)
                app.computeWaveformIfPossible()
            } catch { }
        }
    }

    private func appendTap(_ t: Double) {
        guard var take = currentTake, let idx = currentTakeIndex else { return }
        take.tapTimestamps.append(t)
        take.intervals = ScramblePlannerService.intervals(from: take.tapTimestamps, audioDuration: app.project.audioDuration)
        let videos = take.videoCatalog.map { ($0.key, $0.value) }
        take.cuts = ScramblePlannerService.planCuts(intervals: take.intervals, videos: videos, seed: take.shuffleSeed, avoidanceSec: take.avoidanceWindowSec)
        app.projectV2.tracks.scramble.takes[idx] = take
    }

    private func clearTaps() {
        guard var take = currentTake, let idx = currentTakeIndex else { return }
        take.tapTimestamps.removeAll(); take.intervals.removeAll(); take.cuts.removeAll()
        app.projectV2.tracks.scramble.takes[idx] = take
    }

    private func commitTake() {
        guard let idx = currentTakeIndex else { return }
        var take = app.projectV2.tracks.scramble.takes[idx]
        // Ensure name uniqueness and finalize intervals/cuts
        if take.intervals.isEmpty { take.intervals = ScramblePlannerService.intervals(from: take.tapTimestamps, audioDuration: app.project.audioDuration) }
        if take.cuts.isEmpty { take.cuts = ScramblePlannerService.planCuts(intervals: take.intervals, videos: take.videoCatalog.map { ($0.key, $0.value) }, seed: take.shuffleSeed, avoidanceSec: take.avoidanceWindowSec) }
        if !take.name.hasPrefix("Scramble-Take-") { take.name = nextTakeName() }
        app.projectV2.tracks.scramble.takes[idx] = take
    }

    private func nextTakeName() -> String {
        let base = "Scramble-Take-"
        let nums = app.projectV2.tracks.scramble.takes.compactMap { nameSuffixNumber(base: base, name: $0.name) }
        let n = (nums.max() ?? 0) + 1
        return String(format: "%@%03d", base, n)
    }

    private func nameSuffixNumber(base: String, name: String) -> Int? {
        guard name.hasPrefix(base) else { return nil }
        return Int(name.dropFirst(base.count))
    }

    private func currentPreviewLabel() -> String {
        guard let take = currentTake else { return "Pick a folder to begin" }
        guard !take.intervals.isEmpty, currentIntervalIndex < take.intervals.count, currentIntervalIndex < take.cuts.count else { return "Press Space to tap" }
        let cut = take.cuts[currentIntervalIndex]
        let meta = take.videoCatalog[cut.videoID]
        return "\(meta?.filename ?? "?") @ \(String(format: "%.2f", cut.startSec))s"
    }
}


