import SwiftUI
import AVFoundation
import AVKit
import AppKit

struct ScrambleClipExportView: View {
    @ObservedObject var app: AppState
    @State private var previewPlayer: AVPlayer? = nil
    @State private var status: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview and Export ScrambleClip").font(.title2)
            HStack(spacing: 12) {
                Button("Render Preview") { renderPreview() }
                Button("Export Video") { exportFinal() }
                Button("Reshuffle Cuts") { reshuffle() }
                Spacer()
                Text(status).foregroundColor(.secondary)
            }
            Divider()
            Group {
                if let player = previewPlayer {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let height = width * (16.0/9.0)
                        PlayerView(player: player)
                            .frame(width: width, height: min(geo.size.height, height))
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    }
                    .frame(minHeight: 320)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.windowBackgroundColor))
                        Text("Render Preview to see a video here").foregroundColor(.secondary)
                    }
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }
            }
        }
        .padding()
    }

    private func currentTake() -> TrackScrambleTake? {
        guard let id = app.projectV2.tracks.scramble.currentTakeId else { return nil }
        return app.projectV2.tracks.scramble.takes.first(where: { $0.id == id })
    }

    private func resolveAudioURL() -> URL? {
        guard let data = app.project.audioPathBookmark, let url = BookmarkService.resolveBookmark(data) else { return nil }
        if url.startAccessingSecurityScopedResource() { return url }
        return nil
    }

    private func renderPreview() {
        guard let audioURL = resolveAudioURL(), let take = currentTake() else { status = "Select audio and take"; return }
        status = "Rendering preview…"
        let lyricTake = app.projectV2.tracks.lyric.takes.first(where: { $0.id == app.projectV2.tracks.lyric.currentTakeId })
        ScrambleExportService.renderScramblePreview(audioURL: audioURL, take: take, lyricTake: lyricTake, lyricOffsetMs: 0, backgroundOffsetMs: 0, enableLyrics: true) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    status = "Preview ready"; previewPlayer = AVPlayer(url: url)
                case .failure(let err): status = "Preview failed: \(err.localizedDescription)"
                }
            }
        }
    }

    private func exportFinal() {
        guard let audioURL = resolveAudioURL(), let take = currentTake() else { status = "Select audio and take"; return }
        let panel = NSSavePanel(); panel.allowedFileTypes = ["mp4"]; panel.nameFieldStringValue = "scramble_clip.mp4"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            status = "Exporting…"
            let lyricTake = app.projectV2.tracks.lyric.takes.first(where: { $0.id == app.projectV2.tracks.lyric.currentTakeId })
            ScrambleExportService.exportScramble(audioURL: audioURL, take: take, destinationURL: url, lyricTake: lyricTake, lyricOffsetMs: 0, backgroundOffsetMs: 0, enableLyrics: true) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success: status = "Exported: \(url.lastPathComponent)"
                    case .failure(let err): status = "Export failed: \(err.localizedDescription)"
                    }
                }
            }
        }
    }

    private func reshuffle() {
        guard let idx = app.projectV2.tracks.scramble.takes.firstIndex(where: { $0.id == app.projectV2.tracks.scramble.currentTakeId }) else { return }
        var take = app.projectV2.tracks.scramble.takes[idx]
        take.shuffleSeed = UInt64.random(in: 1...UInt64.max)
        let videos = take.videoCatalog.map { ($0.key, $0.value) }
        if take.intervals.isEmpty { take.intervals = _localIntervals(from: take.tapTimestamps, audioDuration: app.project.audioDuration) }
        take.cuts = _localPlanCuts(intervals: take.intervals, videos: videos, seed: take.shuffleSeed, avoidance: take.avoidanceWindowSec)
        app.projectV2.tracks.scramble.takes[idx] = take
        status = "Reshuffled"
    }
}


