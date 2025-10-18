import SwiftUI
import AppKit
import AVFoundation

struct ScrambleClipEditView: View {
    @ObservedObject var app: AppState
    @State private var nudgeFrames: Int = 0
    private let thumbService = LocalVideoThumbnailService()

    private var takeIndex: Int? {
        guard let id = app.projectV2.tracks.scramble.currentTakeId else { return nil }
        return app.projectV2.tracks.scramble.takes.firstIndex(where: { $0.id == id })
    }
    private var take: TrackScrambleTake? {
        guard let idx = takeIndex else { return nil }
        return app.projectV2.tracks.scramble.takes[idx]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Stepper("Nudge (frames @30fps): \(nudgeFrames)", value: $nudgeFrames, in: -150...150, step: 1)
                Button("Apply Nudge Start") { applyNudge(startDelta: framesToSeconds(nudgeFrames), endDelta: 0) }
                Button("Apply Nudge End") { applyNudge(startDelta: 0, endDelta: framesToSeconds(nudgeFrames)) }
                Spacer()
                Button("Relink Videos…") { relinkVideos() }
                Button("Continue to Export") { app.stage = .scrambleExport }
            }
            Table(rows()) {
                TableColumn("#") { row in Text(String(row.index + 1)) }
                TableColumn("Thumb") { row in thumb(row) }
                TableColumn("Video") { row in Text(row.videoName) }
                TableColumn("StartSec") { row in Text(String(format: "%.3f", row.startSec)) }
                TableColumn("Start") { row in Text(String(format: "%.3f", row.interval.start)) }
                TableColumn("End") { row in Text(String(format: "%.3f", row.interval.end)) }
            }
            .frame(minHeight: 240)
        }
        .padding()
    }

    private func rows() -> [Row] {
        guard let t = take else { return [] }
        var out: [Row] = []
        for i in 0..<min(t.intervals.count, t.cuts.count) {
            let iv = t.intervals[i]
            let cut = t.cuts[i]
            let name = t.videoCatalog[cut.videoID]?.filename ?? "?"
            out.append(Row(index: i, videoName: name, startSec: cut.startSec, interval: iv, fileID: cut.videoID))
        }
        return out
    }

    private struct Row: Identifiable { let id = UUID(); let index: Int; let videoName: String; let startSec: Double; let interval: VideoInterval; let fileID: VideoFileID }

    private func framesToSeconds(_ frames: Int) -> Double { Double(frames) / 30.0 }

    private func applyNudge(startDelta: Double, endDelta: Double) {
        guard var t = take, let idx = takeIndex else { return }
        var updated: [VideoInterval] = []
        var lastEnd = 0.0
        for var it in t.intervals {
            it.start = max(0.0, it.start + startDelta)
            it.end = max(it.start, it.end + endDelta)
            it.start = max(it.start, lastEnd)
            lastEnd = it.end
            updated.append(it)
        }
        t.intervals = updated
        // Re-plan cuts with same seed to keep determinism
        let videos = t.videoCatalog.map { ($0.key, $0.value) }
        t.cuts = ScramblePlannerService.planCuts(intervals: t.intervals, videos: videos, seed: t.shuffleSeed, avoidanceSec: t.avoidanceWindowSec)
        app.projectV2.tracks.scramble.takes[idx] = t
    }

    @ViewBuilder
    private func thumb(_ row: Row) -> some View {
        if let img = thumbService.thumbnail(for: row.fileID, at: row.startSec, targetWidth: 80) {
            Image(nsImage: img)
                .resizable()
                .frame(width: 80, height: 80)
                .clipped()
        } else {
            Color.gray.frame(width: 80, height: 80)
        }
    }

    private func relinkVideos() {
        guard let idx = takeIndex else { return }
        var t = app.projectV2.tracks.scramble.takes[idx]
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let folder = panel.url else { return }
            if let bm = try? BookmarkService.createBookmark(for: folder) {
                let (newCatalog, _) = _scanVideos(root: bm, includeSubfolders: t.includeSubfolders, skipDuplicateFilenames: t.skipDuplicateVideos)
                // Remap by filename
                var filenameToID: [String: VideoFileID] = [:]
                for (fid, meta) in newCatalog { filenameToID[meta.filename] = fid }
                var remappedCatalog: [VideoFileID: VideoMeta] = [:]
                var cuts: [ScrambleCut] = []
                for (i, c) in t.cuts.enumerated() {
                    let name = t.videoCatalog[c.videoID]?.filename
                    if let name, let newId = filenameToID[name], let newMeta = newCatalog[newId] {
                        remappedCatalog[newId] = newMeta
                        cuts.append(ScrambleCut(intervalIndex: i, videoID: newId, startSec: c.startSec))
                    } else {
                        // Keep old if still resolvable
                        remappedCatalog[c.videoID] = t.videoCatalog[c.videoID]
                        cuts.append(c)
                    }
                }
                t.videoFolderBookmark = bm
                // Merge in any new files as additional catalog entries
                for (fid, meta) in newCatalog { if remappedCatalog[fid] == nil { remappedCatalog[fid] = meta } }
                t.videoCatalog = remappedCatalog
                t.cuts = cuts
                app.projectV2.tracks.scramble.takes[idx] = t
            }
        }
    }
}


// Minimal, local thumbnail provider to avoid target-link hiccups
private final class LocalVideoThumbnailService {
    private let cache = NSCache<NSData, NSImage>()
    func thumbnail(for id: VideoFileID, at seconds: Double, targetWidth: CGFloat = 160) -> NSImage? {
        let key = NSMutableData()
        key.append(id.urlBookmark)
        var s = seconds
        key.append(&s, length: MemoryLayout.size(ofValue: s))
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = BookmarkService.resolveBookmark(id.urlBookmark) else { return nil }
        _ = url.startAccessingSecurityScopedResource(); defer { url.stopAccessingSecurityScopedResource() }
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: targetWidth, height: targetWidth * 4)
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
            let ns = NSImage(cgImage: cg, size: .zero)
            cache.setObject(ns, forKey: key)
            return ns
        }
        return nil
    }
}

private func _scanVideos(root bookmark: Data, includeSubfolders: Bool, skipDuplicateFilenames: Bool) -> ([VideoFileID: VideoMeta], [VideoFileID]) {
    guard let rootURL = BookmarkService.resolveBookmark(bookmark) else { return ([:], []) }
    _ = rootURL.startAccessingSecurityScopedResource(); defer { rootURL.stopAccessingSecurityScopedResource() }
    var catalog: [VideoFileID: VideoMeta] = [:]
    var order: [VideoFileID] = []
    var seen: Set<String> = []
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    let opts: FileManager.DirectoryEnumerationOptions = includeSubfolders ? [] : [.skipsSubdirectoryDescendants]
    let en = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: opts)
    let exts: Set<String> = ["mov","mp4","m4v"]
    while let url = en?.nextObject() as? URL {
        guard let rv = try? url.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
        guard exts.contains(url.pathExtension.lowercased()) else { continue }
        let name = url.lastPathComponent
        if skipDuplicateFilenames && seen.contains(name) { continue }
        if skipDuplicateFilenames { seen.insert(name) }
        guard let bm = try? BookmarkService.createBookmark(for: url) else { continue }
        let id = VideoFileID(urlBookmark: bm)
        let asset = AVAsset(url: url)
        let secs = CMTimeGetSeconds(asset.duration)
        var w = 0, h = 0
        if let tr = asset.tracks(withMediaType: .video).first {
            let natural = tr.naturalSize.applying(tr.preferredTransform)
            w = Int(abs(natural.width.rounded())); h = Int(abs(natural.height.rounded()))
        }
        let meta = VideoMeta(filename: name, duration: secs.isFinite ? secs : 0, naturalWidth: w, naturalHeight: h, fileSize: (rv.fileSize != nil ? Int64(rv.fileSize!) : nil), uti: url.pathExtension.lowercased())
        catalog[id] = meta; order.append(id)
    }
    return (catalog, order)
}

