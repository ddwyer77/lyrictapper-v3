import Foundation

struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { self.state = (seed == 0 ? 0x9E3779B97F4A7C15 : seed) }
    mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27
        state = x
        return x &* 2685821657736338717
    }
    mutating func nextInt(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func nextDouble01() -> Double { Double(next()) / Double(UInt64.max) }
}

enum ScramblePlannerService {
    static func intervals(from taps: [Double], audioDuration: Double) -> [VideoInterval] {
        guard audioDuration > 0, !taps.isEmpty else { return [] }
        var out: [VideoInterval] = []
        out.reserveCapacity(taps.count)
        var lastEnd = 0.0
        for i in 0..<taps.count {
            let s = max(0.0, min(taps[i], audioDuration))
            let e = (i + 1 < taps.count) ? max(0.0, min(taps[i+1], audioDuration)) : audioDuration
            let start = max(s, lastEnd)
            let end = max(e, start)
            out.append(VideoInterval(start: start, end: end))
            lastEnd = end
        }
        return out
    }

    static func shuffleBag<T: Equatable>(items: [T], seed: UInt64, cycles: Int = 64) -> [T] {
        guard !items.isEmpty else { return [] }
        var out: [T] = []
        var baseSeed = seed
        for _ in 0..<cycles {
            var bag = items
            seededShuffle(&bag, seed: baseSeed)
            if let last = out.last, let first = bag.first, last == first, bag.count > 1 { bag.swapAt(0, 1) }
            out.append(contentsOf: bag)
            baseSeed &+= 0x9E3779B97F4A7C15
        }
        return out
    }

    static func seededShuffle<T>(_ array: inout [T], seed: UInt64) {
        var rng = SeededRandom(seed)
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = rng.nextInt(i + 1)
            if i != j { array.swapAt(i, j) }
        }
    }

    static func planCuts(
        intervals: [VideoInterval],
        videos: [(id: VideoFileID, meta: VideoMeta)],
        seed: UInt64,
        avoidanceSec: Double
    ) -> [ScrambleCut] {
        guard !videos.isEmpty else { return [] }
        let order = shuffleBag(items: videos.map { $0.id }, seed: seed)
        var which = 0
        var cuts: [ScrambleCut] = []
        var used: [VideoFileID: [Double]] = [:]

        for (idx, iv) in intervals.enumerated() {
            let seg = max(0, iv.end - iv.start)
            // prefer videos that can fit seg
            var chosen: (VideoFileID, VideoMeta, Double)? = nil
            var attempts = 0
            let maxTry = max(8, videos.count * 3)
            while attempts < maxTry && chosen == nil {
                let vid = order[which % order.count]
                which += 1
                attempts += 1
                guard let meta = videos.first(where: { $0.id == vid })?.meta else { continue }
                if seg < meta.duration {
                    var rng = SeededRandom(seed &+ UInt64(idx) &+ UInt64(attempts))
                    let slack = max(0.0, meta.duration - seg)
                    let startCandidate = (slack > 0) ? (rng.nextDouble01() * slack) : 0
                    let history = used[vid] ?? []
                    if !history.contains(where: { abs($0 - startCandidate) < avoidanceSec }) {
                        chosen = (vid, meta, startCandidate)
                        used[vid, default: []].append(startCandidate)
                        break
                    }
                }
            }
            if let c = chosen {
                cuts.append(ScrambleCut(intervalIndex: idx, videoID: c.0, startSec: c.2))
            } else {
                // choose longest, start near end; exporter will freeze-fill remainder
                if let long = videos.max(by: { $0.meta.duration < $1.meta.duration }) {
                    let start = max(0.0, long.meta.duration - seg)
                    cuts.append(ScrambleCut(intervalIndex: idx, videoID: long.id, startSec: start))
                }
            }
        }
        return cuts
    }
}


