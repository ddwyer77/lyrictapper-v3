import Foundation
import UniformTypeIdentifiers

// MARK: - Schema v2 Models

struct ProjectV2: Codable, Equatable {
    var schemaVersion: Int = 2

    var project: ProjectMeta
    var audio: ProjectAudio
    var tracks: ProjectTracks
    var merge: MergeSettings
    var settings: RenderSettings
    // Optional to remain backward compatible with earlier v2 saves
    var lyricsRaw: String?
}

struct ProjectMeta: Codable, Equatable {
    var title: String
    var createdAt: String
    var updatedAt: String
}

struct ProjectAudio: Codable, Equatable {
    var bookmark: Data?
    var duration: Double
    var sampleRate: Double
    var leadIn: Double
}

struct ProjectTracks: Codable, Equatable {
    var lyric: LyricTrack
    var image: ImageTrack
    var scramble: ScrambleTrack
}

struct LyricTrack: Codable, Equatable {
    var takes: [TrackLyricTake]
    var currentTakeId: String?
}

struct ImageTrack: Codable, Equatable {
    var takes: [TrackImageTake]
    var currentTakeId: String?
}

struct TrackLyricTake: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var tapMode: TapModeV2
    var tapTimestamps: [Double]
    var timings: [WordTiming]
    var fontFamily: String?
    var fontFilePath: String?
    var fontSize: Double
    var backgroundMode: LyricBackgroundMode
    var previewPath: String?
}

enum TapModeV2: String, Codable, Equatable { case word, syllable }
enum LyricBackgroundMode: String, Codable, Equatable { case transparent, white }

struct TrackImageTake: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var imageFolderBookmark: Data?
    var includeSubfolders: Bool
    var skipDuplicateImages: Bool
    var imageCatalog: [ImageFileID: ImageMeta]
    var shuffleSeed: UInt64
    var chosenOrder: [ImageFileID]
    var tapTimestamps: [Double]
    var intervals: [ImageInterval]
    var previewPath: String?
}

struct MergeSettings: Codable, Equatable {
    var overlaySource: OverlaySource
    var lyricOffsetMs: Int
    var imageOffsetMs: Int
    var exportPreset: FinalExportPreset
    var backgroundChoice: BackgroundChoice = .imageFlash
    var enableLyrics: Bool = true
}

enum OverlaySource: String, Codable, Equatable { case rerender, alphaMovie }
enum FinalExportPreset: String, Codable, Equatable { case Web_H264, Master_ProRes422 }

enum BackgroundChoice: String, Codable, Equatable { case imageFlash, scrambleClip }

struct RenderSettings: Codable, Equatable {
    var fps: Int
    var width: Int
    var height: Int
}

// MARK: - Helpers

extension ProjectV2 {
    static func newDefault(now: Date = Date(), title: String = "Untitled Project") -> ProjectV2 {
        let iso = ISO8601DateFormatter()
        let meta = ProjectMeta(title: title, createdAt: iso.string(from: now), updatedAt: iso.string(from: now))
        let audio = ProjectAudio(bookmark: nil, duration: 0, sampleRate: 48000, leadIn: 0)
        let lyric = LyricTrack(takes: [], currentTakeId: nil)
        let image = ImageTrack(takes: [], currentTakeId: nil)
        let scramble = ScrambleTrack()
        let tracks = ProjectTracks(lyric: lyric, image: image, scramble: scramble)
        let merge = MergeSettings(overlaySource: .rerender, lyricOffsetMs: 0, imageOffsetMs: 0, exportPreset: .Web_H264, backgroundChoice: .imageFlash, enableLyrics: true)
        let settings = RenderSettings(fps: 30, width: 1080, height: 1920)
        return ProjectV2(project: meta, audio: audio, tracks: tracks, merge: merge, settings: settings, lyricsRaw: "")
    }
}

// MARK: - ScrambleClip Models

struct ScrambleTrack: Codable, Equatable {
    var takes: [TrackScrambleTake] = []
    var currentTakeId: String? = nil
}

struct TrackScrambleTake: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    // Source set
    var videoFolderBookmark: Data?
    var includeSubfolders: Bool
    var skipDuplicateVideos: Bool
    // Catalog & planning
    var videoCatalog: [VideoFileID: VideoMeta]
    var shuffleSeed: UInt64
    var tapTimestamps: [Double]
    var intervals: [VideoInterval]
    var cuts: [ScrambleCut]
    var previewPath: String?
    // Settings
    var avoidanceWindowSec: Double
}

struct VideoFileID: Hashable, Codable {
    let urlBookmark: Data
}

struct VideoMeta: Codable, Equatable {
    let filename: String
    let duration: Double
    let naturalWidth: Int
    let naturalHeight: Int
    let fileSize: Int64?
    let uti: String
}

struct VideoInterval: Codable, Equatable {
    var start: Double
    var end: Double
}

struct ScrambleCut: Codable, Equatable {
    let intervalIndex: Int
    let videoID: VideoFileID
    let startSec: Double
}


