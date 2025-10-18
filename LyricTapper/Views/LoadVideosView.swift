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
            }
            Text("Found videos: \(count)   Total duration: \(String(format: "%.1f s", totalDuration))").foregroundColor(.secondary)
            Spacer()
        }
        .padding()
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
                app.projectV2.tracks.scramble.takes.removeAll()
                // Stash a working take in project V1-like state (we'll commit later in Tap/Edit)
                // For now, just store catalog in project-level scratch to use during tapping
                app.project.imageCatalog.removeAll() // no-op, keeps old code paths safe
                // Keep summary locally
                count = order.count
                totalDuration = order.reduce(0) { $0 + (catalog[$1]?.duration ?? 0) }
                // Cache into a temp take for continuity
                let take = TrackScrambleTake(
                    id: UUID().uuidString,
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
                app.projectV2.tracks.scramble.takes = [take]
                app.projectV2.tracks.scramble.currentTakeId = take.id
            }
        }
    }

    private func onContinue() {
        app.stage = .scrambleTap
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


