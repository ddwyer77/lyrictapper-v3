import SwiftUI
import AVFoundation
import AVKit

struct ImageFlashExportView: View {
    @ObservedObject var app: AppState
    @State private var previewPlayer: AVPlayer? = nil
    @State private var status: String = ""
    @State private var enableLyrics: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview and Export")
                .font(.title2)
            HStack(spacing: 12) {
                Button("Render Preview") { renderPreview() }
                Button("Export Video") { exportFinal() }
                Button("Reshuffle Images") { reshuffle() }
                Spacer()
                Toggle("Add Lyric Overlay", isOn: $enableLyrics)
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
                        Text("Render Preview to see a video here")
                            .foregroundColor(.secondary)
                    }
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }
            }
        }
        .padding()
        .onAppear {
            forceSettings()
            enableLyrics = false
        }
    }

    private func forceSettings() {
        app.project.exportSettings.width = 1080
        app.project.exportSettings.height = 1920
        app.project.exportSettings.fps = 30
    }

    private func renderPreview() {
        guard let audioURL = resolveAudioURL() else { status = "Select accessible audio first"; return }
        forceSettings()
        let lt = enableLyrics ? app.projectV2.tracks.lyric.takes.first(where: { $0.id == app.projectV2.tracks.lyric.currentTakeId }) : nil
        ExportService.renderImageFlashPreview(audioURL: audioURL, intervals: app.project.imageIntervals, destinationSize: CGSize(width: 1080, height: 1920), lyricTake: lt) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    status = "Preview ready"
                    previewPlayer = AVPlayer(url: url)
                case .failure(let err):
                    status = "Preview failed: \(err.localizedDescription)"
                }
            }
        }
    }

    private func exportFinal() {
        guard let audioURL = resolveAudioURL() else { status = "Select accessible audio first"; return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["mp4"]
        panel.nameFieldStringValue = "image_flash.mp4"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            forceSettings()
            let lt = enableLyrics ? app.projectV2.tracks.lyric.takes.first(where: { $0.id == app.projectV2.tracks.lyric.currentTakeId }) : nil
            ExportService.exportImageFlash(audioURL: audioURL, intervals: app.project.imageIntervals, destinationURL: url, lyricTake: lt) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        status = "Exported: \(url.lastPathComponent)"
                    case .failure(let err):
                        status = "Export failed: \(err.localizedDescription)"
                    }
                }
            }
        }
    }

    private func reshuffle() {
        let newSeed = UInt64.random(in: 1...UInt64.max)
        ImageSequenceService.reshuffle(project: &app.project, seed: newSeed)
        app.project.imageIntervals = TimingService.computeImageIntervals(
            taps: app.project.imageTapTimestamps,
            audioDuration: app.project.audioDuration,
            imageOrder: app.project.imageFileIDs
        )
        status = "Reshuffled"
    }

    private func resolveAudioURL() -> URL? {
        guard let data = app.project.audioPathBookmark, let url = BookmarkService.resolveBookmark(data) else { return nil }
        if url.startAccessingSecurityScopedResource() { return url }
        return nil
    }
}


