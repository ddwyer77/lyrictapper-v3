import Foundation
import AVFoundation
import AppKit

final class VideoThumbnailService {
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
        let imgGen = AVAssetImageGenerator(asset: asset)
        imgGen.appliesPreferredTrackTransform = true
        imgGen.maximumSize = CGSize(width: targetWidth, height: targetWidth * 4)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if let cg = try? imgGen.copyCGImage(at: time, actualTime: nil) {
            let ns = NSImage(cgImage: cg, size: .zero)
            cache.setObject(ns, forKey: key)
            return ns
        }
        return nil
    }
}


