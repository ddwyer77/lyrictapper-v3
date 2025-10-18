import Foundation
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

enum ToolKind: String, Codable, CaseIterable, Identifiable {
    case lyrics
    case imageFlash
    case scrambleClip
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    enum Stage: String, Codable, CaseIterable, Identifiable {
        case home
        case dashboard
        case trimAudio
        case lyricTakes
        // Lyric tool stages
        case loadAudio
        case enterLyrics
        case tap
        case edit
        case export
        // Image Flash stages
        case imageTakes
        case loadImages
        case imageTap
        case imageEdit
        case imageExport
        // ScrambleClip stages
        case scrambleTakes
        case loadVideos
        case scrambleTap
        case scrambleEdit
        case scrambleExport
        case mergeExport
        var id: String { rawValue }
    }

    @Published var stage: Stage = .home
    @Published var activeTool: ToolKind = .lyrics
    @Published var project: Project
    @Published var projectV2: ProjectV2 = ProjectV2.newDefault()
    @Published var waveform: [WaveformBin] = []
    @Published var showLogs: Bool = false
    @Published var logger: Logger = .shared
    @Published var projectManager: ProjectManager = ProjectManager()

    // Keep a cached, security-scoped URL while in session
    private var scopedAudioURL: URL?

    init(now: Date = Date()) {
        let defaultSettings = ExportSettings(width: 1080, height: 1080, fps: 30, fontFamily: "Arial Narrow", fontFilePath: nil, fontSizePct: 0.18, textColor: "#000000")
        self.project = Project(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: now),
            updatedAt: ISO8601DateFormatter().string(from: now),
            audioPathBookmark: nil,
            audioDuration: 0,
            lyricsRaw: "",
            tokens: [],
            taps: [],
            timings: [],
            offsetMs: 0,
            exportSettings: defaultSettings
        )
        self.project.mode = .lyrics
    }

    func switchTool(_ tool: ToolKind) {
        activeTool = tool
        switch tool {
        case .lyrics:
            // If audio already chosen, skip picker
            if project.audioPathBookmark != nil && project.audioDuration > 0 {
                stage = .enterLyrics
            } else {
                stage = .loadAudio
            }
            project.mode = .lyrics
        case .imageFlash:
            // Reuse chosen audio for image flash; skip audio picker entirely
            stage = .loadImages
            project.mode = .imageFlash
        case .scrambleClip:
            // Reuse chosen audio; go to load videos step
            stage = .loadVideos
            project.mode = .imageFlash
        }
    }

    func updateLyrics(_ text: String) {
        project.lyricsRaw = text
        project.tokens = Tokenizer.tokenize(lyricsRaw: text)
        project.updatedAt = ISO8601DateFormatter().string(from: Date())
        logger.log(.info, "Lyrics updated", context: "tokens=\(project.tokens.count)")
        // Persist into v2 as well
        projectV2.lyricsRaw = text
    }

    func applyOffset(ms: Int) {
        project.offsetMs += ms
        recomputeTimings()
    }

    func setOffset(ms: Int) {
        project.offsetMs = ms
        recomputeTimings()
    }

    func setAudioDuration(seconds: Double) {
        project.audioDuration = max(0, seconds)
        recomputeTimings()
        logger.log(.info, "Audio duration set", context: String(format: "%.3fs", project.audioDuration))
    }

    func setTaps(_ taps: [Tap]) {
        project.taps = taps
        recomputeTimings()
        logger.log(.info, "Taps replaced", context: "count=\(taps.count)")
    }

    func pushTap(atSeconds seconds: Double) {
        project.taps.append(Tap(t: seconds))
        recomputeTimings()
        logger.log(.info, "Tap recorded", context: String(format: "t=%.3f", seconds))
    }

    func clearTaps() {
        project.taps.removeAll()
        project.timings.removeAll()
        project.updatedAt = ISO8601DateFormatter().string(from: Date())
        logger.log(.warn, "All taps cleared")
    }

    func recomputeTimings() {
        if project.tapMode == .perSyllable {
            project.timings = TimingService.computeTimingsPerSyllable(
                taps: project.taps,
                tokens: project.tokens,
                audioDuration: project.audioDuration,
                offsetMs: project.offsetMs
            )
        } else {
            project.timings = TimingService.computeTimings(
                taps: project.taps,
                tokens: project.tokens,
                audioDuration: project.audioDuration,
                offsetMs: project.offsetMs
            )
        }
        project.updatedAt = ISO8601DateFormatter().string(from: Date())
        logger.log(.info, "Timings recomputed", context: "timings=\(project.timings.count), offsetMs=\(project.offsetMs)")
    }
}

extension AppState {
    func setAudioBookmark(_ data: Data) {
        project.audioPathBookmark = data
        project.updatedAt = ISO8601DateFormatter().string(from: Date())
        // Invalidate prior scope
        if let url = scopedAudioURL { url.stopAccessingSecurityScopedResource() }
        if let url = BookmarkService.resolveBookmark(data), url.startAccessingSecurityScopedResource() {
            scopedAudioURL = url
        } else {
            scopedAudioURL = nil
        }
    }

    func computeWaveformIfPossible(targetBins: Int = 800) {
        var urlToUse: URL? = scopedAudioURL
        if urlToUse == nil, let data = project.audioPathBookmark, let resolved = BookmarkService.resolveBookmark(data), resolved.startAccessingSecurityScopedResource() {
            scopedAudioURL = resolved
            urlToUse = resolved
        }
        guard let url = urlToUse else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let bins = (try? WaveformService.computeRMSBins(url: url, targetBins: targetBins)) ?? []
            DispatchQueue.main.async { [weak self] in
                self?.waveform = bins
                self?.logger.log(.info, "Waveform computed", context: "bins=\(bins.count)")
            }
        }
    }
}

// MARK: - V2 Takes Management
extension AppState {
    func setCurrentLyricTake(_ id: String?) {
        projectV2.tracks.lyric.currentTakeId = id
        // autosave hook
    }
    func setCurrentImageTake(_ id: String?) {
        projectV2.tracks.image.currentTakeId = id
        // autosave hook
        // Sync working image order with selected take for consistency in previews/exports
        if let id, let take = projectV2.tracks.image.takes.first(where: { $0.id == id }), !take.chosenOrder.isEmpty {
            project.imageFileIDs = take.chosenOrder
        }
    }

    func duplicateLyricTake(_ id: String) {
        guard let idx = projectV2.tracks.lyric.takes.firstIndex(where: { $0.id == id }) else { return }
        var take = projectV2.tracks.lyric.takes[idx]
        take.id = UUID().uuidString
        take.name = nextLyricTakeName()
        projectV2.tracks.lyric.takes.insert(take, at: idx + 1)
    }

    func deleteLyricTake(_ id: String) {
        projectV2.tracks.lyric.takes.removeAll { $0.id == id }
        if projectV2.tracks.lyric.currentTakeId == id { projectV2.tracks.lyric.currentTakeId = projectV2.tracks.lyric.takes.first?.id }
    }

    func duplicateImageTake(_ id: String) {
        guard let idx = projectV2.tracks.image.takes.firstIndex(where: { $0.id == id }) else { return }
        var take = projectV2.tracks.image.takes[idx]
        take.id = UUID().uuidString
        take.name = nextImageTakeName()
        projectV2.tracks.image.takes.insert(take, at: idx + 1)
    }

    func deleteImageTake(_ id: String) {
        projectV2.tracks.image.takes.removeAll { $0.id == id }
        if projectV2.tracks.image.currentTakeId == id { projectV2.tracks.image.currentTakeId = projectV2.tracks.image.takes.first?.id }
    }

    private func nextLyricTakeName() -> String {
        let base = "Lyric-Take-"
        let nums = projectV2.tracks.lyric.takes.compactMap { nameSuffixNumber(base: base, name: $0.name) }
        let n = (nums.max() ?? 0) + 1
        return String(format: "%@%03d", base, n)
    }

    private func nextImageTakeName() -> String {
        let base = "Image-Take-"
        let nums = projectV2.tracks.image.takes.compactMap { nameSuffixNumber(base: base, name: $0.name) }
        let n = (nums.max() ?? 0) + 1
        return String(format: "%@%03d", base, n)
    }

    private func nameSuffixNumber(base: String, name: String) -> Int? {
        guard name.hasPrefix(base) else { return nil }
        let suffix = name.dropFirst(base.count)
        return Int(suffix)
    }
}

// MARK: - Commit current sessions as takes (v2)
extension AppState {
    func commitCurrentLyricAsTake() {
        let take = TrackLyricTake(
            id: UUID().uuidString,
            name: nextLyricTakeName(),
            tapMode: (project.tapMode == .perSyllable ? .syllable : .word),
            tapTimestamps: project.taps.map { $0.t },
            timings: project.timings,
            fontFamily: project.exportSettings.fontFamily,
            fontFilePath: project.exportSettings.fontFilePath,
            fontSize: project.exportSettings.fontSizePct ?? 0.18,
            backgroundMode: .transparent,
            previewPath: nil
        )
        projectV2.tracks.lyric.takes.append(take)
        projectV2.tracks.lyric.currentTakeId = take.id
        // autosave hint
        // projectManager.markDirty()
    }

    func commitCurrentImageAsTake() {
        // Compute intervals from current taps + order to avoid stale/empty intervals
        let computedIntervals = TimingService.computeImageIntervals(
            taps: project.imageTapTimestamps,
            audioDuration: project.audioDuration,
            imageOrder: project.imageFileIDs
        )
        let take = TrackImageTake(
            id: UUID().uuidString,
            name: nextImageTakeName(),
            imageFolderBookmark: project.imageFolderBookmark,
            includeSubfolders: project.includeSubfolders,
            skipDuplicateImages: project.skipDuplicateImages,
            imageCatalog: project.imageCatalog,
            shuffleSeed: project.shuffleSeed ?? 0,
            chosenOrder: project.imageFileIDs,
            tapTimestamps: project.imageTapTimestamps,
            intervals: computedIntervals,
            previewPath: nil
        )
        projectV2.tracks.image.takes.append(take)
        projectV2.tracks.image.currentTakeId = take.id
        // autosave hint
        // projectManager.markDirty()
    }
}


