import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AppKit

struct LoadVideosView: View {
    @ObservedObject var app: AppState
    @State private var includeSubfolders: Bool = false
    @State private var skipDuplicates: Bool = false
    @State private var folderURL: URL? = nil
    @State private var count: Int = 0
    @State private var totalDuration: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Load Videos for ScrambleClip").font(.title2)
            HStack(spacing: 12) {
                Button("Choose Folder…") { pickFolder() }
                Toggle("Include subfolders", isOn: $includeSubfolders)
                Toggle("Skip duplicate filenames", isOn: $skipDuplicates)
                Spacer()
                Button("Continue") { onContinue() }.disabled(folderURL == nil || count == 0)
            }
            if let url = folderURL {
                Text("Selected: \(url.path)").foregroundColor(.secondary)
            } else if let t = currentTake(), let url = resolvedFolderURL(from: t) {
                Text("Selected: \(url.path)").foregroundColor(.secondary)
            }
            Text("Found videos: \(countIfKnown())   Total duration: \(String(format: "%.1f s", totalDurationIfKnown()))").foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .onAppear { hydrateFromProject() }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            folderURL = url
            if let bm = try? BookmarkService.createBookmark(for: url) {
                let (catalog, order) = _scanVideos(root: bm, includeSubfolders: includeSubfolders, skipDuplicateFilenames: skipDuplicates)
                // Keep summary locally
                count = order.count
                totalDuration = order.reduce(0) { $0 + (catalog[$1]?.duration ?? 0) }
                // Create or update a working take and set it current
                let existingIdx = app.projectV2.tracks.scramble.takes.firstIndex(where: { $0.name == "Scramble-Take-001" })
                let newId = existingIdx.flatMap { app.projectV2.tracks.scramble.takes[$0].id } ?? UUID().uuidString
                var take = TrackScrambleTake(
                    id: newId,
                    name: "Scramble-Take-001",
                    videoFolderBookmark: bm,
                    includeSubfolders: includeSubfolders,
                    skipDuplicateVideos: skipDuplicates,
                    videoCatalog: catalog,
                    shuffleSeed: UInt64.random(in: 1...UInt64.max),
                    tapTimestamps: [],
                    intervals: [],
                    cuts: [],
                    previewPath: nil,
                    avoidanceWindowSec: 1.5
                )
                if let existingIdx = existingIdx {
                    app.projectV2.tracks.scramble.takes[existingIdx] = take
                    app.projectV2.tracks.scramble.currentTakeId = newId
                } else {
                    app.projectV2.tracks.scramble.takes.append(take)
                    app.projectV2.tracks.scramble.currentTakeId = newId
                }
            }
        }
    }

    private func onContinue() {
        app.stage = .scrambleTap
    }

    // MARK: - Persistence helpers
    private func currentTake() -> TrackScrambleTake? {
        guard let id = app.projectV2.tracks.scramble.currentTakeId else { return nil }
        return app.projectV2.tracks.scramble.takes.first(where: { $0.id == id })
    }

    private func hydrateFromProject() {
        guard let t = currentTake() else { return }
        includeSubfolders = t.includeSubfolders
        skipDuplicates = t.skipDuplicateVideos
        count = t.videoCatalog.count
        totalDuration = t.videoCatalog.values.reduce(0) { $0 + $1.duration }
        if let url = resolvedFolderURL(from: t) { folderURL = url }
    }

    private func resolvedFolderURL(from take: TrackScrambleTake) -> URL? {
        guard let bm = take.videoFolderBookmark, let url = BookmarkService.resolveBookmark(bm) else { return nil }
        return url
    }

    private func countIfKnown() -> Int { count > 0 ? count : (currentTake()?.videoCatalog.count ?? 0) }
    private func totalDurationIfKnown() -> Double {
        if totalDuration > 0 { return totalDuration }
        if let t = currentTake() { return t.videoCatalog.values.reduce(0) { $0 + $1.duration } }
        return 0
    }

    // Local fallback to avoid target-link hiccups
    private func _scanVideos(root bookmark: Data, includeSubfolders: Bool, skipDuplicateFilenames: Bool) -> ([VideoFileID: VideoMeta], [VideoFileID]) {
        guard let rootURL = BookmarkService.resolveBookmark(bookmark) else { return ([:], []) }
        _ = rootURL.startAccessingSecurityScopedResource(); defer { rootURL.stopAccessingSecurityScopedResource() }
        var catalog: [VideoFileID: VideoMeta] = [:]
        var order: [VideoFileID] = []
        var seen: Set<String> = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .typeIdentifierKey]
        let opts: FileManager.DirectoryEnumerationOptions = includeSubfolders ? [] : [.skipsSubdirectoryDescendants]
        let en = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: opts)
        let supportedExts: Set<String> = ["mov","mp4","m4v"]
        while let url = en?.nextObject() as? URL {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard supportedExts.contains(ext) else { continue }
            let name = url.lastPathComponent
            if skipDuplicateFilenames && seen.contains(name) { continue }
            if skipDuplicateFilenames { seen.insert(name) }
            guard let fileBm = try? BookmarkService.createBookmark(for: url) else { continue }
            let id = VideoFileID(urlBookmark: fileBm)
            let asset = AVAsset(url: url)
            let secs = CMTimeGetSeconds(asset.duration)
            var w = 0, h = 0
            if let track = asset.tracks(withMediaType: .video).first {
                let natural = track.naturalSize.applying(track.preferredTransform)
                w = Int(abs(natural.width.rounded())); h = Int(abs(natural.height.rounded()))
            }
            let meta = VideoMeta(filename: name, duration: secs.isFinite ? secs : 0, naturalWidth: w, naturalHeight: h, fileSize: (rv.fileSize != nil ? Int64(rv.fileSize!) : nil), uti: ext)
            catalog[id] = meta; order.append(id)
        }
        return (catalog, order)
    }
}


