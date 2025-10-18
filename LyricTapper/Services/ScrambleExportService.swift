import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import AppKit
import CoreImage

enum ScrambleExportServiceError: Error { case writerFailed, readerFailed, compositionFailed }

enum ScrambleExportService {
    static func renderScramblePreview(
        audioURL: URL,
        take: TrackScrambleTake,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let videoOnlyURL = tempDir.appendingPathComponent("scramble_preview_\(UUID().uuidString).mp4")
                try renderVideoOnly(audioURL: audioURL, take: take, outputURL: videoOnlyURL, width: 1080, height: 1920, fps: 30)
                let withAudioURL = tempDir.appendingPathComponent("scramble_preview_with_audio_\(UUID().uuidString).mp4")
                try muxAudioVideo(audioURL: audioURL, videoURL: videoOnlyURL, destinationURL: withAudioURL)
                completion(.success(withAudioURL))
            } catch { completion(.failure(error)) }
        }
    }

    static func exportScramble(
        audioURL: URL,
        take: TrackScrambleTake,
        destinationURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) { try? FileManager.default.removeItem(at: destinationURL) }
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let videoOnlyURL = tempDir.appendingPathComponent("scramble_video_\(UUID().uuidString).mp4")
                try renderVideoOnly(audioURL: audioURL, take: take, outputURL: videoOnlyURL, width: 1080, height: 1920, fps: 30)
                try muxAudioVideo(audioURL: audioURL, videoURL: videoOnlyURL, destinationURL: destinationURL)
                completion(.success(destinationURL))
            } catch { completion(.failure(error)) }
        }
    }
}

// MARK: - Core rendering

private func renderVideoOnly(audioURL: URL, take: TrackScrambleTake, outputURL: URL, width: Int, height: Int, fps: Int) throws {
    let duration = try audioDuration(audioURL)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 14_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw ScrambleExportServiceError.writerFailed }
    writer.add(input)
    let srcAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: srcAttrs)
    writer.startWriting(); writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw ScrambleExportServiceError.writerFailed }

    // Prepare intervals and cuts if missing
    let intervals = take.intervals.isEmpty ? ScramblePlannerService.intervals(from: take.tapTimestamps, audioDuration: duration) : take.intervals
    let videosList: [(VideoFileID, VideoMeta)] = take.videoCatalog.map { ($0.key, $0.value) }
    let cuts: [ScrambleCut] = take.cuts.isEmpty ? ScramblePlannerService.planCuts(intervals: intervals, videos: videosList, seed: take.shuffleSeed, avoidanceSec: take.avoidanceWindowSec) : take.cuts

    // Resolve URLs and hold scopes for used videos
    var idToURL: [VideoFileID: URL] = [:]
    var scoped: [URL] = []
    for c in cuts {
        if idToURL[c.videoID] == nil, let url = BookmarkService.resolveBookmark(c.videoID.urlBookmark) {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            idToURL[c.videoID] = url
        }
    }
    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
    var frameTime = CMTime.zero
    let context = CIContext(options: nil)
    let rgb = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    for (idx, iv) in intervals.enumerated() {
        let seg = max(0.0, iv.end - iv.start)
        let framesInSeg = Int(ceil(seg * Double(fps)))
        guard idx < cuts.count else { break }
        let cut = cuts[idx]
        guard let url = idToURL[cut.videoID] else {
            // Draw black segment if missing
            for _ in 0..<framesInSeg { try appendBlackFrame(pool: pool, width: width, height: height, adaptor: adaptor, input: input, frameTime: &frameTime, frameDuration: frameDuration) }
            continue
        }
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            for _ in 0..<framesInSeg { try appendBlackFrame(pool: pool, width: width, height: height, adaptor: adaptor, input: input, frameTime: &frameTime, frameDuration: frameDuration) }
            continue
        }
        let start = CMTime(seconds: cut.startSec, preferredTimescale: 600)
        let dur = CMTime(seconds: seg, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, duration: dur)
        guard let reader = try? AVAssetReader(asset: asset) else {
            for _ in 0..<framesInSeg { try appendBlackFrame(pool: pool, width: width, height: height, adaptor: adaptor, input: input, frameTime: &frameTime, frameDuration: frameDuration) }
            continue
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        output.supportsRandomAccess = false
        output.reset(forReadingTimeRanges: [NSValue(timeRange: timeRange)])
        if reader.canAdd(output) { reader.add(output) }
        reader.timeRange = timeRange
        guard reader.startReading() else {
            for _ in 0..<framesInSeg { try appendBlackFrame(pool: pool, width: width, height: height, adaptor: adaptor, input: input, frameTime: &frameTime, frameDuration: frameDuration) }
            continue
        }

        var lastImage: CGImage? = nil
        var produced = 0
        // For each frame slot, consume next sample if available, otherwise freeze last
        while produced < framesInSeg {
            autoreleasepool {
                if input.isReadyForMoreMediaData == false { Thread.sleep(forTimeInterval: 0.002) }
                var cgImage: CGImage? = lastImage
                if let sample = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) {
                    let ci = CIImage(cvImageBuffer: pb).transformed(by: preferredUprightTransform(for: track))
                    cgImage = context.createCGImage(ci, from: ci.extent)
                    lastImage = cgImage
                }
                if cgImage == nil {
                    // Freeze or black
                    if lastImage == nil {
                        // draw black
                        try? appendBlackFrame(pool: pool, width: width, height: height, adaptor: adaptor, input: input, frameTime: &frameTime, frameDuration: frameDuration)
                    } else {
                        try? appendDrawnFrame(image: lastImage!, width: width, height: height, adaptor: adaptor, input: input, frameTime: &frameTime, frameDuration: frameDuration, rgb: rgb, bitmapInfo: bitmapInfo)
                    }
                    produced += 1
                    return
                }
                if let cg = cgImage {
                    try? appendDrawnFrame(image: cg, width: width, height: height, adaptor: adaptor, input: input, frameTime: &frameTime, frameDuration: frameDuration, rgb: rgb, bitmapInfo: bitmapInfo)
                    produced += 1
                }
            }
        }
    }

    input.markAsFinished()
    let g = DispatchGroup(); g.enter(); writer.finishWriting { g.leave() }; g.wait()
    if writer.status != .completed { throw writer.error ?? ScrambleExportServiceError.writerFailed }
}

private func appendBlackFrame(pool: CVPixelBufferPool, width: Int, height: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput, frameTime: inout CMTime, frameDuration: CMTime) throws {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var pbOut: CVPixelBuffer? = nil
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
    guard let pb = pbOut else { throw ScrambleExportServiceError.writerFailed }
    CVPixelBufferLockBaseAddress(pb, [])
    if let base = CVPixelBufferGetBaseAddress(pb) {
        let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.setFillColor(NSColor.black.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    _ = adaptor.append(pb, withPresentationTime: frameTime)
    frameTime = CMTimeAdd(frameTime, frameDuration)
}

private func appendDrawnFrame(image: CGImage, width: Int, height: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput, frameTime: inout CMTime, frameDuration: CMTime, rgb: CGColorSpace, bitmapInfo: UInt32) throws {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var pbOut: CVPixelBuffer? = nil
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
    guard let pb = pbOut else { throw ScrambleExportServiceError.writerFailed }
    CVPixelBufferLockBaseAddress(pb, [])
    if let base = CVPixelBufferGetBaseAddress(pb) {
        let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: rgb,
            bitmapInfo: bitmapInfo
        )
        ctx?.setFillColor(NSColor.black.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let iw = image.width
        let ih = image.height
        if iw > 0 && ih > 0 {
            let scale = CGFloat(width) / CGFloat(iw)
            let destH = Int(CGFloat(ih) * scale)
            let y = (height - destH) / 2
            ctx?.interpolationQuality = .high
            ctx?.draw(image, in: CGRect(x: 0, y: y, width: width, height: destH))
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    _ = adaptor.append(pb, withPresentationTime: frameTime)
    frameTime = CMTimeAdd(frameTime, frameDuration)
}

private func preferredUprightTransform(for track: AVAssetTrack) -> CGAffineTransform {
    var t = track.preferredTransform
    // Normalize: convert negative widths/heights to positive by adjusting origin
    var rect = CGRect(origin: .zero, size: track.naturalSize.applying(t))
    rect.origin = .zero
    let fix = CGAffineTransform(translationX: rect.width < 0 ? -rect.width : 0, y: rect.height < 0 ? -rect.height : 0)
    t = t.concatenating(fix)
    return t
}

// MARK: - Audio helpers

private func audioDuration(_ url: URL) throws -> Double {
    let asset = AVAsset(url: url)
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite && seconds > 0 else { throw ScrambleExportServiceError.compositionFailed }
    return seconds
}

private func muxAudioVideo(audioURL: URL, videoURL: URL, destinationURL: URL) throws {
    let composition = AVMutableComposition()
    let audioAsset = AVAsset(url: audioURL)
    let videoAsset = AVAsset(url: videoURL)
    guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else { throw ScrambleExportServiceError.compositionFailed }
    let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration), of: videoTrack, at: .zero)
    if let audioTrack = audioAsset.tracks(withMediaType: .audio).first {
        let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration), of: audioTrack, at: .zero)
    }
    if FileManager.default.fileExists(atPath: destinationURL.path) { try? FileManager.default.removeItem(at: destinationURL) }
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw ScrambleExportServiceError.compositionFailed }
    export.outputURL = destinationURL
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    let g = DispatchGroup(); var err: Error?; g.enter(); export.exportAsynchronously { if export.status != .completed { err = export.error ?? ScrambleExportServiceError.compositionFailed }; g.leave() }; g.wait()
    if let e = err { throw e }
}


