import SwiftUI
import AVFoundation
import AppKit

struct ScrambleClipTapView: View {
    @ObservedObject var app: AppState
    @StateObject var audio = AudioService()
    @State private var status: String = ""
    @State private var currentIntervalIndex: Int = 0
    @State private var previewImage: NSImage? = nil

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
                if let img = previewImage {
                    GeometryReader { geo in
                        let width = geo.size.width
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: width)
                            .position(x: width/2.0, y: geo.size.height/2.0)
                    }
                } else {
                    VStack(spacing: 6) {
                        Text("ScrambleClip Preview").foregroundColor(.white)
                        Text(currentPreviewLabel()).foregroundColor(.white.opacity(0.7))
                    }
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
        .onAppear {
            prepareAudio()
            // Rehydrate preview image when returning
            if let take = currentTake { updatePreviewFor(index: min(currentIntervalIndex, max(0, take.cuts.count - 1)), in: take) }
        }
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
        take.intervals = _localIntervals(from: take.tapTimestamps, audioDuration: app.project.audioDuration)
        let videos = take.videoCatalog.map { ($0.key, $0.value) }
        take.cuts = _localPlanCuts(intervals: take.intervals, videos: videos, seed: take.shuffleSeed, avoidance: take.avoidanceWindowSec)
        app.projectV2.tracks.scramble.takes[idx] = take
        updatePreviewFor(index: currentIntervalIndex, in: take)
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
        if take.intervals.isEmpty { take.intervals = _localIntervals(from: take.tapTimestamps, audioDuration: app.project.audioDuration) }
        if take.cuts.isEmpty { take.cuts = _localPlanCuts(intervals: take.intervals, videos: take.videoCatalog.map { ($0.key, $0.value) }, seed: take.shuffleSeed, avoidance: take.avoidanceWindowSec) }
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

    private func updatePreviewFor(index: Int, in take: TrackScrambleTake) {
        guard index < take.cuts.count, let url = BookmarkService.resolveBookmark(take.cuts[index].videoID.urlBookmark) else { previewImage = nil; return }
        _ = url.startAccessingSecurityScopedResource(); defer { url.stopAccessingSecurityScopedResource() }
        let gen = AVAssetImageGenerator(asset: AVAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 4096)
        let t = CMTime(seconds: max(0, take.cuts[index].startSec), preferredTimescale: 600)
        if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
            previewImage = NSImage(cgImage: cg, size: .zero)
        } else {
            previewImage = nil
        }
    }
}


// Local planners to avoid cross-file dependency while wiring
private func _localIntervals(from taps: [Double], audioDuration: Double) -> [VideoInterval] {
    guard audioDuration > 0, !taps.isEmpty else { return [] }
    var out: [VideoInterval] = []
    var lastEnd = 0.0
    for i in 0..<taps.count {
        let s = max(0.0, min(taps[i], audioDuration))
        let e = (i + 1 < taps.count) ? max(0.0, min(taps[i+1], audioDuration)) : audioDuration
        let start = max(s, lastEnd)
        let end = max(e, start)
        out.append(VideoInterval(start: start, end: end))
        lastEnd = end
    }
    return out
}

private struct _RNG { var state: UInt64; mutating func next() -> UInt64 { var x = state == 0 ? 0x9E3779B97F4A7C15 : state; x ^= x >> 12; x ^= x << 25; x ^= x >> 27; state = x; return x &* 2685821657736338717 }; mutating func nextInt(_ n: Int) -> Int { Int(next() % UInt64(max(1,n))) }; mutating func next01() -> Double { Double(next()) / Double(UInt64.max) } }

private func _localPlanCuts(intervals: [VideoInterval], videos: [(VideoFileID, VideoMeta)], seed: UInt64, avoidance: Double) -> [ScrambleCut] {
    guard !videos.isEmpty else { return [] }
    var rng = _RNG(state: seed)
    var used: [VideoFileID: [Double]] = [:]
    var out: [ScrambleCut] = []
    for (i, iv) in intervals.enumerated() {
        let seg = max(0.0, iv.end - iv.start)
        var chosen: (VideoFileID, Double)? = nil
        for _ in 0..<max(8, videos.count * 2) {
            let pick = videos[rng.nextInt(videos.count)]
            if seg < pick.1.duration {
                let slack = max(0.0, pick.1.duration - seg)
                let start = (slack > 0) ? rng.next01() * slack : 0
                if !(used[pick.0] ?? []).contains(where: { abs($0 - start) < avoidance }) { chosen = (pick.0, start); used[pick.0, default: []].append(start); break }
            }
        }
        if let c = chosen {
            out.append(ScrambleCut(intervalIndex: i, videoID: c.0, startSec: c.1))
        } else if let long = videos.max(by: { $0.1.duration < $1.1.duration }) {
            let start = max(0.0, long.1.duration - seg)
            out.append(ScrambleCut(intervalIndex: i, videoID: long.0, startSec: start))
        }
    }
    return out
}

