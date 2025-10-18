import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ProjectsLandingView: View {
    @ObservedObject var app: AppState

    @State private var status: String = ""
    @State private var pickedAudioURL: URL? = nil
    @State private var waveformBins: [WaveformBin] = []
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var durationSec: Double = 0
    @State private var playbackPosition: Double = 0
    @State private var isPreviewing: Bool = false
    @StateObject private var previewAudio = AudioService()
    @State private var previewTimer: Timer? = nil

    var body: some View {
        VStack(spacing: 24) {
            Text("Welcome to Lyric Tapper")
                .font(.largeTitle)

            VStack(spacing: 12) {
                Button("New Project – Choose Audio…") { chooseAudio() }
                if let url = pickedAudioURL {
                    Text("Audio: \(url.lastPathComponent)")
                        .foregroundColor(.secondary)
                }
                if pickedAudioURL != nil {
                    WaveformTrimView(bins: waveformBins, duration: durationSec, start: $startTime, end: $endTime, playhead: playbackPosition)
                    HStack(spacing: 12) {
                        Button(action: togglePreview) {
                            Label(isPreviewing ? "Pause" : "Play", systemImage: isPreviewing ? "pause.fill" : "play.fill")
                        }
                        Button(action: stopPreview) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        Text(String(format: "Start: %.2fs", startTime)).foregroundColor(.secondary)
                        Text(String(format: "End: %.2fs", endTime)).foregroundColor(.secondary)
                        Text(String(format: "Len: %.2fs", max(0, endTime - startTime))).foregroundColor(.secondary)
                        Button("Trim Audio") { trimOnLanding() }.disabled((endTime - startTime) < 0.1)
                    }
                }
                HStack(spacing: 12) {
                    Button("Start with Lyric Tool") { startWith(.lyrics) }
                        .disabled(pickedAudioURL == nil)
                    Button("Start with Image Flash") { startWith(.imageFlash) }
                        .disabled(pickedAudioURL == nil)
                    Button("Start with Scramble Clip") { startWith(.scrambleClip) }
                        .disabled(pickedAudioURL == nil)
                }
            }

            Divider().padding(.vertical, 8)

            HStack(spacing: 12) {
                Button("Open Project…") { openLegacyOrV2() }
                Text(status).foregroundColor(.secondary)
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Projects").font(.headline)
                if app.projectManager.recent.isEmpty {
                    Text("No recent projects yet").foregroundColor(.secondary)
                } else {
                    List(app.projectManager.recent, id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent)
                            Spacer()
                            Button("Open") { app.projectManager.open(url: url); app.stage = .dashboard }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }
            HStack(spacing: 12) {
                Button("Save Project As…") { saveProjectAs() }
                if let url = app.projectManager.currentURL { Text("Saving to: \(url.lastPathComponent)").foregroundColor(.secondary) }
                Spacer()
            }
        }
        .padding(24)
        .onAppear {
            // When returning to landing, restore picked audio and waveform from the current project
            if pickedAudioURL == nil {
                if let bm = app.projectV2.audio.bookmark, let url = BookmarkService.resolveBookmark(bm) {
                    pickedAudioURL = url
                    durationSec = app.projectV2.audio.duration
                    if durationSec <= 0 {
                        let asset = AVAsset(url: url)
                        durationSec = CMTimeGetSeconds(asset.duration)
                    }
                    startTime = 0
                    endTime = max(0.1, durationSec)
                    if !app.waveform.isEmpty {
                        waveformBins = app.waveform
                    } else {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let bins = (try? WaveformService.computeRMSBins(url: url, targetBins: 800)) ?? []
                            DispatchQueue.main.async {
                                waveformBins = bins
                                app.waveform = bins
                            }
                        }
                    }
                    // Load audio for preview
                    try? previewAudio.loadFile(url: url)
                    previewAudio.duration = durationSec
                }
            } else if waveformBins.isEmpty && !app.waveform.isEmpty {
                waveformBins = app.waveform
            }
        }
        .onDisappear { stopPreview() }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            pickedAudioURL = url
            status = "Picked audio: \(url.lastPathComponent)"
            prepareFor(url)
            // Load into preview engine
            try? previewAudio.loadFile(url: url)
        }
    }

    private func startWith(_ tool: ToolKind) {
        guard let url = pickedAudioURL else { return }
        do {
            let bookmark = try BookmarkService.createBookmark(for: url)
            app.setAudioBookmark(bookmark)
            app.setAudioDuration(seconds: durationSec)
            app.switchTool(tool)
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func openLegacyOrV2() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json", "ltproj", "ltproj.json"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Try v2 first
                let p = try ProjectStore.loadV2(from: url)
                app.projectV2 = p
                app.projectManager.open(url: url)
                // Commit audio bookmark into v1 shim so legacy views use it automatically
                if let data = p.audio.bookmark { app.setAudioBookmark(data) }
                status = "Opened project (v2): \(url.lastPathComponent)"
                app.stage = .dashboard
            } catch {
                // Fallback to v1 legacy
                if let v1 = try? ProjectStore.loadV1(from: url) {
                    if let data = v1.audioPathBookmark, let resolved = BookmarkService.resolveBookmark(data) {
                        app.setAudioBookmark(data)
                        let asset = AVAsset(url: resolved)
                        app.setAudioDuration(seconds: CMTimeGetSeconds(asset.duration))
                        app.switchTool(.lyrics)
                        status = "Opened legacy project"
                    }
                } else {
                    status = "Open failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = (app.projectV2.project.title.isEmpty ? "Untitled Project" : app.projectV2.project.title) + ".json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            app.projectManager.current = app.projectV2
            app.projectManager.save(to: url)
            status = "Saved: \(url.lastPathComponent)"
        }
    }
}

// MARK: - Landing helpers
extension ProjectsLandingView {
    private func prepareFor(_ url: URL) {
        let asset = AVAsset(url: url)
        durationSec = CMTimeGetSeconds(asset.duration)
        startTime = 0
        endTime = max(0.1, durationSec)
        DispatchQueue.global(qos: .userInitiated).async {
            let bins = (try? WaveformService.computeRMSBins(url: url, targetBins: 800)) ?? []
            DispatchQueue.main.async {
                waveformBins = bins
                app.waveform = bins
            }
        }
    }

    private func trimOnLanding() {
        guard let url = pickedAudioURL else { return }
        let s = max(0, min(startTime, endTime - 0.1))
        let e = max(s + 0.1, endTime)
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("trim_\(UUID().uuidString).m4a")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try exportTrimmedAudio(source: url, start: s, end: e, to: outURL)
                DispatchQueue.main.async {
                    pickedAudioURL = outURL
                    status = String(format: "Trimmed to %.2fs", e - s)
                    prepareFor(outURL)
                    // Reload preview to trimmed copy
                    try? previewAudio.loadFile(url: outURL)
                    // Persist to v2 immediately so Save works without starting a tool
                    do {
                        let bm = try BookmarkService.createBookmark(for: outURL)
                        app.projectV2.audio.bookmark = bm
                        app.projectV2.audio.duration = e - s
                    } catch { }
                }
            } catch {
                DispatchQueue.main.async { status = "Trim failed: \(error.localizedDescription)" }
            }
        }
    }

    private func togglePreview() {
        guard pickedAudioURL != nil else { return }
        if isPreviewing {
            previewAudio.pause()
            isPreviewing = false
            stopTimer()
        } else {
            // Seek to start and play; stop at end
            previewAudio.seek(to: startTime)
            try? previewAudio.play()
            isPreviewing = true
            startTimer()
        }
    }

    private func stopPreview() {
        previewAudio.stop()
        isPreviewing = false
        playbackPosition = startTime
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        playbackPosition = startTime
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            let t = previewAudio.currentTimeSeconds()
            playbackPosition = t
            if t >= endTime {
                stopPreview()
            }
        }
        RunLoop.main.add(previewTimer!, forMode: .common)
    }

    private func stopTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }
}

private func exportTrimmedAudio(source: URL, start: Double, end: Double, to dest: URL) throws {
    let asset = AVAsset(url: source)
    guard let track = asset.tracks(withMediaType: .audio).first else { throw ExportServiceError.missingAudio }
    let composition = AVMutableComposition()
    let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let startTime = CMTime(seconds: start, preferredTimescale: 600)
    let duration = CMTime(seconds: end - start, preferredTimescale: 600)
    try compAudio.insertTimeRange(CMTimeRange(start: startTime, duration: duration), of: track, at: .zero)

    if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw ExportServiceError.compositionFailed }
    exporter.outputURL = dest
    exporter.outputFileType = .m4a
    let g = DispatchGroup(); var err: Error?; g.enter()
    exporter.exportAsynchronously { if exporter.status != .completed { err = exporter.error ?? ExportServiceError.compositionFailed }; g.leave() }
    g.wait()
    if let e = err { throw e }
}


