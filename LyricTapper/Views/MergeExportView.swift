import SwiftUI
import AVFoundation
import AppKit
import AVKit

struct MergeExportView: View {
    @ObservedObject var app: AppState

    @State private var status: String = ""
    @State private var lyricOffsetMs: Int = 0
    @State private var imageOffsetMs: Int = 0
    @State private var enableLyrics: Bool = true
    @State private var backgroundChoice: BackgroundChoice = .imageFlash
    @State private var selectedLyricTakeId: String? = nil
    @State private var selectedImageTakeId: String? = nil
    @State private var previewPlayer: AVPlayer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge & Export Final").font(.title2)

            // Takes pickers
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lyric Take").font(.headline)
                    Picker("Lyric Take", selection: $selectedLyricTakeId) {
                        Text("None").tag(Optional<String>(nil))
                        ForEach(app.projectV2.tracks.lyric.takes) { t in
                            Text(t.name).tag(Optional(t.id))
                        }
                    }
                    .frame(width: 260)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Background").font(.headline)
                    Picker("Background", selection: $backgroundChoice) {
                        Text("ImageFlash").tag(BackgroundChoice.imageFlash)
                        Text("ScrambleClip").tag(BackgroundChoice.scrambleClip)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    if backgroundChoice == .imageFlash {
                        Picker("Image Take", selection: $selectedImageTakeId) {
                            ForEach(app.projectV2.tracks.image.takes) { t in
                                Text(t.name).tag(Optional(t.id))
                            }
                        }
                        .frame(width: 260)
                    } else {
                        Picker("Scramble Take", selection: $selectedImageTakeId) {
                            ForEach(app.projectV2.tracks.scramble.takes) { t in
                                Text(t.name).tag(Optional(t.id))
                            }
                        }
                        .frame(width: 260)
                    }
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Stepper("Lyric Offset (ms): \(lyricOffsetMs)", value: $lyricOffsetMs, in: -5000...5000, step: 10)
                Stepper("Image Offset (ms): \(imageOffsetMs)", value: $imageOffsetMs, in: -5000...5000, step: 10)
                Toggle("Enable Lyrics Overlay", isOn: $enableLyrics)
                Spacer()
                Button("Render Preview") { renderPreview() }
                Button("Export Final") { exportFinal() }
            }
            Text(status).foregroundColor(.secondary)
            Divider()
            Group {
                if let player = previewPlayer {
                    GeometryReader { geo in
                        // Use 1080x1920 default unless we add editable settings here
                        let targetAspect = CGFloat(1080) / CGFloat(1920)
                        let width = geo.size.width
                        let height = min(geo.size.height, width / targetAspect)
                        PlayerView(player: player)
                            .frame(width: width, height: height)
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    }
                    .frame(minHeight: 320)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.windowBackgroundColor))
                        Text("Render Preview to see a merged video here")
                            .foregroundColor(.secondary)
                    }
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }
            }
            Spacer()
        }
        .padding(24)
        .onAppear {
            selectedLyricTakeId = selectedLyricTakeId ?? app.projectV2.tracks.lyric.currentTakeId
            selectedImageTakeId = selectedImageTakeId ?? app.projectV2.tracks.image.currentTakeId ?? app.projectV2.tracks.image.takes.first?.id
            backgroundChoice = app.projectV2.merge.backgroundChoice
            enableLyrics = app.projectV2.merge.enableLyrics
        }
    }

    private func exportFinal() {
        guard let audioURL = resolveAudioURL() else { status = "Select accessible audio first"; return }
        let settings = RenderSettings(fps: 30, width: 1080, height: 1920)
        var lyricTake: TrackLyricTake? = app.projectV2.tracks.lyric.takes.first(where: { $0.id == (selectedLyricTakeId ?? app.projectV2.tracks.lyric.currentTakeId) })
        if lyricTake == nil || (lyricTake?.timings.isEmpty == true) { lyricTake = makeLyricTakeFromV1() }
        status = "Exporting…"
        switch backgroundChoice {
        case .imageFlash:
            let imageTake = app.projectV2.tracks.image.takes.first(where: { $0.id == (selectedImageTakeId ?? app.projectV2.tracks.image.currentTakeId) })
            let intervals: [ImageInterval]
            if let t = imageTake, !t.intervals.isEmpty {
                intervals = t.intervals
            } else if let t = imageTake {
                intervals = TimingService.computeImageIntervals(
                    taps: t.tapTimestamps,
                    audioDuration: app.project.audioDuration,
                    imageOrder: t.chosenOrder
                )
            } else {
                intervals = app.project.imageIntervals
            }
            CompositorService.exportFinal(audioURL: audioURL, imageIntervals: intervals, settings: settings, lyricTake: enableLyrics ? lyricTake : nil, lyricOffsetMs: lyricOffsetMs, imageOffsetMs: imageOffsetMs) { result in
                DispatchQueue.main.async { handleExportResult(result) }
            }
        case .scrambleClip:
            guard let takeId = app.projectV2.tracks.scramble.currentTakeId, let take = app.projectV2.tracks.scramble.takes.first(where: { $0.id == takeId }) else { status = "Select a Scramble take"; return }
            let panel = NSSavePanel(); panel.allowedFileTypes = ["mp4"]; panel.nameFieldStringValue = "scramble_merge.mp4"
            panel.begin { resp in
                guard resp == .OK, let url = panel.url else { return }
                _ScrambleExportShim.export(audioURL: audioURL, take: take, destinationURL: url, lyricTake: lyricTake, lyricOffsetMs: lyricOffsetMs, backgroundOffsetMs: imageOffsetMs, enableLyrics: enableLyrics) { result in
                    DispatchQueue.main.async { handleExportResult(result) }
                }
            }
        }
    }

    private func renderPreview() {
        guard let audioURL = resolveAudioURL() else { status = "Select accessible audio first"; return }
        let settings = RenderSettings(fps: 30, width: 1080, height: 1920)
        var lyricTake: TrackLyricTake? = app.projectV2.tracks.lyric.takes.first(where: { $0.id == (selectedLyricTakeId ?? app.projectV2.tracks.lyric.currentTakeId) })
        if lyricTake == nil || (lyricTake?.timings.isEmpty == true) { lyricTake = makeLyricTakeFromV1() }
        status = "Rendering preview…"
        switch backgroundChoice {
        case .imageFlash:
            let imageTake = app.projectV2.tracks.image.takes.first(where: { $0.id == (selectedImageTakeId ?? app.projectV2.tracks.image.currentTakeId) })
            let intervals: [ImageInterval]
            if let t = imageTake, !t.intervals.isEmpty {
                intervals = t.intervals
            } else if let t = imageTake {
                intervals = TimingService.computeImageIntervals(
                    taps: t.tapTimestamps,
                    audioDuration: app.project.audioDuration,
                    imageOrder: t.chosenOrder
                )
            } else {
                intervals = app.project.imageIntervals
            }
            CompositorService.exportFinal(audioURL: audioURL, imageIntervals: intervals, settings: settings, lyricTake: enableLyrics ? lyricTake : nil, lyricOffsetMs: lyricOffsetMs, imageOffsetMs: imageOffsetMs) { result in
                DispatchQueue.main.async { handlePreviewResult(result) }
            }
        case .scrambleClip:
            guard let takeId = app.projectV2.tracks.scramble.currentTakeId, let take = app.projectV2.tracks.scramble.takes.first(where: { $0.id == takeId }) else { status = "Select a Scramble take"; return }
            _ScrambleExportShim.preview(audioURL: audioURL, take: take, lyricTake: lyricTake, lyricOffsetMs: lyricOffsetMs, backgroundOffsetMs: imageOffsetMs, enableLyrics: enableLyrics) { result in
                DispatchQueue.main.async { handlePreviewResult(result) }
            }
        }
    }

    private func handlePreviewResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): status = "Preview ready"; previewPlayer = AVPlayer(url: url)
        case .failure(let err): status = "Preview failed: \(err.localizedDescription)"
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): status = "Exported: \(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let err): status = "Export failed: \(err.localizedDescription)"
        }
    }

    private func makeLyricTakeFromV1() -> TrackLyricTake {
        TrackLyricTake(
            id: UUID().uuidString,
            name: "Lyric-Overlay",
            tapMode: (app.project.tapMode == .perSyllable ? .syllable : .word),
            tapTimestamps: app.project.taps.map { $0.t },
            timings: app.project.timings,
            fontFamily: app.project.exportSettings.fontFamily,
            fontFilePath: app.project.exportSettings.fontFilePath,
            fontSize: app.project.exportSettings.fontSizePct ?? 0.18,
            backgroundMode: .transparent,
            previewPath: nil
        )
    }

    private func resolveAudioURL() -> URL? {
        guard let data = app.project.audioPathBookmark, let url = BookmarkService.resolveBookmark(data) else { return nil }
        if url.startAccessingSecurityScopedResource() { return url }
        return nil
    }
}

// Temporary shim resolves when ScrambleExportService is not yet linked into target
private enum _ScrambleExportShim {
    static func preview(audioURL: URL, take: TrackScrambleTake, lyricTake: TrackLyricTake?, lyricOffsetMs: Int, backgroundOffsetMs: Int, enableLyrics: Bool, completion: @escaping (Result<URL, Error>) -> Void) {
        completion(.failure(NSError(domain: "Stub", code: -1, userInfo: [NSLocalizedDescriptionKey: "Scramble exporter not linked"])))
    }
    static func export(audioURL: URL, take: TrackScrambleTake, destinationURL: URL, lyricTake: TrackLyricTake?, lyricOffsetMs: Int, backgroundOffsetMs: Int, enableLyrics: Bool, completion: @escaping (Result<URL, Error>) -> Void) {
        completion(.failure(NSError(domain: "Stub", code: -1, userInfo: [NSLocalizedDescriptionKey: "Scramble exporter not linked"])))
    }
}


