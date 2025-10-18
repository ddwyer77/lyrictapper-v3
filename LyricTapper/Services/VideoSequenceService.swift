import Foundation
import AVFoundation
import UniformTypeIdentifiers

enum VideoSequenceService {
    static func scanFolder(root bookmark: Data, includeSubfolders: Bool, skipDuplicateFilenames: Bool = false) -> ([VideoFileID: VideoMeta], [VideoFileID]) {
        guard let rootURL = BookmarkService.resolveBookmark(bookmark) else { return ([:], []) }
        _ = rootURL.startAccessingSecurityScopedResource()
        defer { rootURL.stopAccessingSecurityScopedResource() }

        var catalog: [VideoFileID: VideoMeta] = [:]
        var order: [VideoFileID] = []
        var seenNames: Set<String> = []

        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .typeIdentifierKey]
        let options: FileManager.DirectoryEnumerationOptions = includeSubfolders ? [] : [.skipsSubdirectoryDescendants]
        let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: options)
        let supported: Set<UTType> = [UTType(filenameExtension: "mov"), UTType(filenameExtension: "mp4"), UTType(filenameExtension: "m4v")].compactMap { $0 }.reduce(into: Set<UTType>()) { acc, t in acc.insert(t) }

        while let entry = enumerator?.nextObject() as? URL {
            do {
                let rv = try entry.resourceValues(forKeys: Set(keys))
                guard rv.isRegularFile == true else { continue }
                guard let utiStr = rv.typeIdentifier, let uti = UTType(utiStr), supported.contains(uti) else { continue }
                let filename = entry.lastPathComponent
                if skipDuplicateFilenames && seenNames.contains(filename) { continue }
                if skipDuplicateFilenames { seenNames.insert(filename) }

                // Create per-file bookmark
                guard let fileBookmark = try? BookmarkService.createBookmark(for: entry) else { continue }
                let id = VideoFileID(urlBookmark: fileBookmark)

                // Probe meta via AVAsset (duration and natural size with preferredTransform)
                let asset = AVAsset(url: entry)
                let seconds = CMTimeGetSeconds(asset.duration)
                var width: Int = 0
                var height: Int = 0
                if let track = asset.tracks(withMediaType: .video).first {
                    let natural = track.naturalSize.applying(track.preferredTransform)
                    width = Int(abs(natural.width.rounded()))
                    height = Int(abs(natural.height.rounded()))
                }
                let meta = VideoMeta(
                    filename: filename,
                    duration: seconds.isFinite ? seconds : 0,
                    naturalWidth: width,
                    naturalHeight: height,
                    fileSize: (rv.fileSize != nil ? Int64(rv.fileSize!) : nil),
                    uti: utiStr
                )
                catalog[id] = meta
                order.append(id)
            } catch {
                continue
            }
        }
        return (catalog, order)
    }
}


