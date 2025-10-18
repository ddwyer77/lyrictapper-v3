import Foundation
import AVFoundation
import AppKit
import CoreVideo
import CoreGraphics
import QuartzCore
import CoreMedia

enum ExportServiceError: Error {
    case missingAudio
    case compositionFailed
    case writerFailed
}

enum ExportService {
    static func makePreviewComposition(
        audioURL: URL,
        timings: [WordTiming],
        settings: ExportSettings
    ) throws -> (AVMutableComposition, AVVideoComposition, CALayer) {
        let asset = AVAsset(url: audioURL)
        let composition = AVMutableComposition()

        // Audio track
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try compAudio?.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
        }

        // Video placeholder track
        let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let duration = asset.duration
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        // Insert empty time range to define video duration; render size comes from videoComposition.renderSize
        compVideo?.insertEmptyTimeRange(timeRange)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        videoComposition.renderSize = CGSize(width: settings.width, height: settings.height)

        // Root animation layer
        let parent = CALayer()
        parent.frame = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
        parent.backgroundColor = NSColor.white.cgColor

        let textContainer = CALayer()
        textContainer.frame = parent.bounds
        parent.addSublayer(textContainer)

        let minSide = CGFloat(min(settings.width, settings.height))
        let fontSize = CGFloat((settings.fontSizePct ?? 0.18)) * minSide

        for w in timings {
            let text = CATextLayer()
            text.string = w.word
            text.alignmentMode = .center
            text.foregroundColor = NSColor.black.cgColor
            text.contentsScale = 2.0
            text.frame = CGRect(x: 0, y: (parent.bounds.height - fontSize) / 2.0, width: parent.bounds.width, height: fontSize * 1.2)
            text.opacity = 0
            if let family = settings.fontFamily, let font = NSFont(name: family, size: fontSize) {
                text.font = font
                text.fontSize = font.pointSize
            } else {
                text.font = NSFont.systemFont(ofSize: fontSize)
                text.fontSize = fontSize
            }

            let start = CMTime(seconds: w.start, preferredTimescale: 600)
            let end = CMTime(seconds: w.end, preferredTimescale: 600)
            let startSeconds = CMTimeGetSeconds(start)
            let endSeconds = CMTimeGetSeconds(end)

            // Animate opacity on/off across the timing window
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = startSeconds
            appear.duration = 0.001
            appear.isRemovedOnCompletion = false
            appear.fillMode = .forwards

            let disappear = CABasicAnimation(keyPath: "opacity")
            disappear.fromValue = 1
            disappear.toValue = 0
            disappear.beginTime = endSeconds
            disappear.duration = 0.001
            disappear.isRemovedOnCompletion = false
            disappear.fillMode = .forwards

            let group = CAAnimationGroup()
            group.animations = [appear, disappear]
            group.duration = endSeconds + 1 // ensure group spans full range
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards

            text.add(group, forKey: "visibility")
            textContainer.addSublayer(text)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo!)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        return (composition, videoComposition, parent)
    }

    static func export(
        audioURL: URL,
        timings: [WordTiming],
        settings: ExportSettings,
        destinationURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Remove existing file if needed
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try? FileManager.default.removeItem(at: destinationURL)
                }

                awaitMain {
                    Logger.shared.log(.info, "Export starting", context: "dest=\(destinationURL.lastPathComponent), timings=\(timings.count), size=\(settings.width)x\(settings.height)@\(settings.fps)")
                }
                // Step 1: render video-only file via AVAssetWriter
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let videoOnlyURL = tempDir.appendingPathComponent("lyric_tapper_video_\(UUID().uuidString).mp4")
                try renderVideoOnly(to: videoOnlyURL, duration: try audioDuration(audioURL), timings: timings, settings: settings)

                // Step 2: mux with original audio via AVMutableComposition and export
                try muxAudioVideo(audioURL: audioURL, videoURL: videoOnlyURL, destinationURL: destinationURL)

                awaitMain {
                    Logger.shared.log(.info, "Export completed", context: destinationURL.lastPathComponent)
                }
                completion(.success(destinationURL))
            } catch {
                awaitMain {
                    let ns = error as NSError
                    Logger.shared.log(.error, "Export exception", context: "code=\(ns.code) domain=\(ns.domain) desc=\(ns.localizedDescription)")
                }
                completion(.failure(error))
            }
        }
    }

    static func renderPreviewFile(
        audioURL: URL,
        timings: [WordTiming],
        settings: ExportSettings,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let videoOnlyURL = tempDir.appendingPathComponent("lyric_tapper_preview_\(UUID().uuidString).mp4")
                try renderVideoOnly(to: videoOnlyURL, duration: try audioDuration(audioURL), timings: timings, settings: settings)
                // Mux audio for preview playback with sound
                let withAudioURL = tempDir.appendingPathComponent("lyric_tapper_preview_with_audio_\(UUID().uuidString).mp4")
                try muxAudioVideo(audioURL: audioURL, videoURL: videoOnlyURL, destinationURL: withAudioURL)
                completion(.success(withAudioURL))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private func awaitMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
}

// MARK: - Helpers (Writer + Mux)

private func audioDuration(_ url: URL) throws -> Double {
    let asset = AVAsset(url: url)
    let duration = asset.duration
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite && seconds > 0 else { throw ExportServiceError.missingAudio }
    return seconds
}

private func renderVideoOnly(to outputURL: URL, duration: Double, timings: [WordTiming], settings: ExportSettings) throws {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: settings.width,
        AVVideoHeightKey: settings.height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: max(2_000_000, settings.width * settings.height),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { throw ExportServiceError.writerFailed }
    writer.add(videoInput)

    let sourcePixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: settings.width,
        kCVPixelBufferHeightKey as String: settings.height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: sourcePixelBufferAttributes)

    // Build CoreAnimation layer tree (no implicit animations; we set opacity per-frame)
    let parent = CALayer()
    parent.frame = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
    parent.backgroundColor = NSColor.white.cgColor

    let minSide = CGFloat(min(settings.width, settings.height))
    let fontSize = CGFloat((settings.fontSizePct ?? 0.18)) * minSide

    var textLayers: [CATextLayer] = []
    textLayers.reserveCapacity(timings.count)
    for w in timings where !w.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let text = CATextLayer()
        text.string = w.word
        text.alignmentMode = .center
        text.foregroundColor = NSColor.black.cgColor
        text.contentsScale = 2.0
        text.frame = CGRect(x: 0, y: (parent.bounds.height - fontSize) / 2.0, width: parent.bounds.width, height: fontSize * 1.2)
        text.opacity = 0
        if let path = settings.fontFilePath, let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL), let cgFont = CGFont(provider), let nsFont = NSFont(name: cgFont.postScriptName as String? ?? "", size: fontSize) {
            text.font = nsFont
            text.fontSize = nsFont.pointSize
        } else if let family = settings.fontFamily, let font = NSFont(name: family, size: fontSize) {
            text.font = font
            text.fontSize = font.pointSize
        } else {
            text.font = NSFont.systemFont(ofSize: fontSize)
            text.fontSize = fontSize
        }
        parent.addSublayer(text)
        textLayers.append(text)
    }

    let fps = max(1, settings.fps)
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    let totalFrames = Int(ceil(duration * Double(fps)))

    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    Logger.logAsync(.info, "Writer started", context: outputURL.lastPathComponent)

    guard let pbPool = adaptor.pixelBufferPool else { throw ExportServiceError.writerFailed }

    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    var frameTime = CMTime.zero
    var frameIndex = 0

    while frameIndex < totalFrames {
        autoreleasepool {
            while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }

            var pxbufOut: CVPixelBuffer? = nil
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pbPool, &pxbufOut)
            guard status == kCVReturnSuccess, let pxbuf = pxbufOut else {
                Logger.logAsync(.error, "CVPixelBufferPoolCreatePixelBuffer failed", context: String(status))
                videoInput.markAsFinished()
                writer.cancelWriting()
                return
            }
            CVPixelBufferLockBaseAddress(pxbuf, [])
            if let base = CVPixelBufferGetBaseAddress(pxbuf) {
                let ctx = CGContext(
                    data: base,
                    width: settings.width,
                    height: settings.height,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pxbuf),
                    space: rgbColorSpace,
                    bitmapInfo: bitmapInfo
                )
                // White background
                ctx?.setFillColor(NSColor.white.cgColor)
                ctx?.fill(CGRect(x: 0, y: 0, width: settings.width, height: settings.height))

                let t = Double(frameIndex) / Double(fps)
                // Toggle word visibility based on timings at this frame time
                for (i, w) in timings.enumerated() {
                    let visible = (t >= w.start) && (t < w.end)
                    textLayers[i].opacity = visible ? 1.0 : 0.0
                }
                parent.render(in: ctx!)
            }
            CVPixelBufferUnlockBaseAddress(pxbuf, [])
            let ok = adaptor.append(pxbuf, withPresentationTime: frameTime)
            if !ok {
                Logger.logAsync(.error, "Adaptor append failed", context: "t=\(CMTimeGetSeconds(frameTime))")
                videoInput.markAsFinished()
                writer.cancelWriting()
                return
            }
        }
        frameIndex += 1
        frameTime = CMTimeAdd(frameTime, frameDuration)
    }

    videoInput.markAsFinished()
    let finishGroup = DispatchGroup()
    finishGroup.enter()
    writer.finishWriting {
        finishGroup.leave()
    }
    finishGroup.wait()
    Logger.logAsync(.info, "Writer finished", context: writer.status == .completed ? "completed" : (writer.error?.localizedDescription ?? "unknown"))
    if writer.status != .completed { throw writer.error ?? ExportServiceError.writerFailed }
}

private func muxAudioVideo(audioURL: URL, videoURL: URL, destinationURL: URL) throws {
    let composition = AVMutableComposition()
    let audioAsset = AVAsset(url: audioURL)
    let videoAsset = AVAsset(url: videoURL)

    guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else { throw ExportServiceError.compositionFailed }
    let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration), of: videoTrack, at: .zero)

    if let audioTrack = audioAsset.tracks(withMediaType: .audio).first {
        let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration), of: audioTrack, at: .zero)
    }

    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try? FileManager.default.removeItem(at: destinationURL)
    }

    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw ExportServiceError.compositionFailed }
    export.outputURL = destinationURL
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true

    let group = DispatchGroup()
    var exportErr: Error?
    group.enter()
    export.exportAsynchronously {
        if export.status != .completed {
            exportErr = export.error ?? ExportServiceError.compositionFailed
        }
        group.leave()
    }
    group.wait()
    if let e = exportErr { throw e }
}

// MARK: - Image Flash Export

extension ExportService {
    static func renderImageFlashPreview(
        audioURL: URL,
        intervals: [ImageInterval],
        destinationSize: CGSize,
        lyricTake: TrackLyricTake? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let videoOnlyURL = tempDir.appendingPathComponent("image_flash_preview_\(UUID().uuidString).mp4")
                try renderImageFlashVideoOnly(to: videoOnlyURL, audioURL: audioURL, intervals: intervals, width: Int(destinationSize.width), height: Int(destinationSize.height), fps: 30, lyricTake: lyricTake)
                // Mux audio so preview includes sound
                let withAudioURL = tempDir.appendingPathComponent("image_flash_preview_with_audio_\(UUID().uuidString).mp4")
                try muxAudioVideo(audioURL: audioURL, videoURL: videoOnlyURL, destinationURL: withAudioURL)
                completion(.success(withAudioURL))
            } catch { completion(.failure(error)) }
        }
    }

    static func exportImageFlash(
        audioURL: URL,
        intervals: [ImageInterval],
        destinationURL: URL,
        lyricTake: TrackLyricTake? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) { try? FileManager.default.removeItem(at: destinationURL) }
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let videoOnlyURL = tempDir.appendingPathComponent("image_flash_video_\(UUID().uuidString).mp4")
                try renderImageFlashVideoOnly(to: videoOnlyURL, audioURL: audioURL, intervals: intervals, width: 1080, height: 1920, fps: 30, lyricTake: lyricTake)
                try muxAudioVideo(audioURL: audioURL, videoURL: videoOnlyURL, destinationURL: destinationURL)
                completion(.success(destinationURL))
            } catch { completion(.failure(error)) }
        }
    }
}

private func renderImageFlashVideoOnly(to outputURL: URL, audioURL: URL, intervals: [ImageInterval], width: Int, height: Int, fps: Int, lyricTake: TrackLyricTake? = nil) throws {
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
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { throw ExportServiceError.writerFailed }
    writer.add(videoInput)
    let srcAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: srcAttrs)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw ExportServiceError.writerFailed }
    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    let totalFrames = Int(ceil(duration * Double(fps)))
    var frameTime = CMTime.zero
    var frameIndex = 0

    // Pre-resolve URLs for intervals (deduplicate keys), and start security-scoped access
    var fileIdToURL: [ImageFileID: URL] = [:]
    var startedScopedURLs: [URL] = []
    for iv in intervals {
        if fileIdToURL[iv.fileID] == nil, let url = BookmarkService.resolveBookmark(iv.fileID.urlBookmark) {
            if url.startAccessingSecurityScopedResource() { startedScopedURLs.append(url) }
            fileIdToURL[iv.fileID] = url
        }
    }
    defer { startedScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
    let decodeCache = ImageDecodeCache(targetWidth: width)

    // Prepare optional lyric overlay
    let ctFont: CTFont? = {
        guard let take = lyricTake else { return nil }
        let relSize: CGFloat = CGFloat(take.fontSize)
        let fontSize = max(12.0, relSize * CGFloat(min(width, height)))
        let family = take.fontFamily ?? "Helvetica Neue"
        return CTFontCreateWithName(family as CFString, fontSize, nil)
    }()
    while frameIndex < totalFrames {
        autoreleasepool {
            while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var pxbufOut: CVPixelBuffer? = nil
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pxbufOut)
            guard let pb = pxbufOut else { return }
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
                let t = Double(frameIndex) / Double(fps)
                if let iv = intervals.first(where: { t >= $0.start && t < $0.end }) {
                    if let url = fileIdToURL[iv.fileID], let cg = decodeCache.decodedScaledToWidth(url: url) {
                        let scale = CGFloat(width) / CGFloat(cg.width)
                        let destH = Int(CGFloat(cg.height) * scale)
                        let y = (height - destH) / 2
                        ctx?.interpolationQuality = .high
                        ctx?.draw(cg, in: CGRect(x: 0, y: y, width: width, height: destH))
                    } else {
                        Logger.logAsync(.warn, "Missing or unreadable image during export", context: "interval t=\(t)")
                    }
                }
                if let f = ctFont, let take = lyricTake {
                    let w = take.timings.last(where: { $0.start <= t && t < $0.end })
                    if let word = w?.word, !word.isEmpty {
                        let white = CGColor(gray: 1.0, alpha: 1.0)
                        let black = CGColor(gray: 0.0, alpha: 1.0)
                        let attrs: [NSAttributedString.Key: Any] = [
                            NSAttributedString.Key(kCTFontAttributeName as String): f,
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
                            NSAttributedString.Key(kCTStrokeColorAttributeName as String): black,
                            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -2.0
                        ]
                        let attr = NSAttributedString(string: word, attributes: attrs)
                        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
                        let bounds = CTLineGetImageBounds(line, ctx!)
                        let x = (CGFloat(width) - bounds.width) / 2.0 - bounds.origin.x
                        let y = (CGFloat(height) - bounds.height) / 2.0 - bounds.origin.y
                        ctx?.textPosition = CGPoint(x: x, y: y)
                        CTLineDraw(line, ctx!)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let ok = adaptor.append(pb, withPresentationTime: frameTime)
            if !ok { videoInput.markAsFinished(); writer.cancelWriting(); return }
        }
        frameIndex += 1
        frameTime = CMTimeAdd(frameTime, frameDuration)
    }

    videoInput.markAsFinished()
    let g = DispatchGroup(); g.enter(); writer.finishWriting { g.leave() }; g.wait()
    if writer.status != .completed { throw writer.error ?? ExportServiceError.writerFailed }
}



