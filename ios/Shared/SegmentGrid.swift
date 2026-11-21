import Foundation

// Segment length and video frame times on one grid that both tracks of the fMP4 stream share.
// Why (docs/PLAN.md "1." and "5. 소리", build 17 clicks): a segment can only hold whole video frames
// and whole AAC frames (1024 samples). 0.5 s is 15 video frames but 23.4375 AAC frames, and ReplayKit
// frame times are uneven, so every segment's audio ended somewhere else than its video, and the
// player's per-segment timestamps (EXTINF from the video) disagreed with the audio a little in each
// segment. A segment length that is a whole number of both, with video frames placed exactly on the
// 1/30 s grid, makes both tracks start and end together in every segment.

/// Pure arithmetic for the shared grid (unit-tested in SegmentGridTests).
enum SegmentGrid {
    /// Video frame rate of the stream (HLSSegmenter.Config.frameRate).
    static let frameRate = 30
    /// AAC-LC frame length in samples.
    static let samplesPerAACFrame = 1024
    /// Time scale for every stream time (video frames, audio samples, segment interval): the audio
    /// sample rate, which a video frame divides exactly at 30 fps (1600 ticks).
    static let timescale = AudioTrackFormat.sampleRate

    /// Smallest segment length, in audio samples, that is a whole number of video frames and of AAC
    /// frames, or nil when a video frame is not a whole number of samples.
    /// 30 fps at 48 kHz: lcm(1600, 1024) = 25600 samples = 0.5333 s = 16 video frames = 25 AAC frames.
    static func periodSamples(frameRate: Int = frameRate, sampleRate: Int = AudioTrackFormat.sampleRate,
                              aacFrame: Int = samplesPerAACFrame) -> Int? {
        guard frameRate > 0, sampleRate > 0, aacFrame > 0, sampleRate % frameRate == 0 else { return nil }
        return lcm(sampleRate / frameRate, aacFrame)
    }

    /// The whole multiple of the period nearest to `target` (at least one period), in seconds.
    /// Falls back to `target` when there is no period.
    static func alignedSeconds(near target: Double, frameRate: Int = frameRate,
                               sampleRate: Int = AudioTrackFormat.sampleRate,
                               aacFrame: Int = samplesPerAACFrame) -> Double {
        guard target.isFinite, target > 0,
              let period = periodSamples(frameRate: frameRate, sampleRate: sampleRate, aacFrame: aacFrame)
        else { return target }
        let periodSeconds = Double(period) / Double(sampleRate)
        let count = max(1, Int((target / periodSeconds).rounded()))
        return Double(count * period) / Double(sampleRate)
    }

    /// Video frames in a segment of this length (at least 1).
    static func framesPerSegment(seconds: Double, frameRate: Int = frameRate) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return max(1, Int((seconds * Double(frameRate)).rounded()))
    }

    /// True when the length is (within a microsecond) a whole number of video frames and of AAC frames.
    static func isAligned(seconds: Double, frameRate: Int = frameRate,
                          sampleRate: Int = AudioTrackFormat.sampleRate,
                          aacFrame: Int = samplesPerAACFrame) -> Bool {
        guard let period = periodSamples(frameRate: frameRate, sampleRate: sampleRate, aacFrame: aacFrame),
              seconds.isFinite, seconds > 0 else { return false }
        let periods = seconds * Double(sampleRate) / Double(period)
        return abs(periods - periods.rounded()) * Double(period) / Double(sampleRate) < 1e-6 && periods.rounded() >= 1
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    private static func lcm(_ a: Int, _ b: Int) -> Int { a / gcd(a, b) * b }
}

/// Places video frames on the 1/frameRate grid from the session start (frame index 0), so segment
/// boundaries (every `framesPerSegment` frames) fall exactly on a frame.
/// - A frame goes to the nearest grid slot; if that slot is taken it moves to the next one, but never
///   more than one frame ahead of its real time (then it is dropped, like a too-fast frame).
/// - When frames skip over a segment boundary (static screen: ReplayKit sends nothing and the
///   pipeline repeats the last frame only every ~0.3 s), the caller first repeats the previous frame
///   on each skipped boundary (`fillers`), so the writer can still cut exactly there.
struct VideoFrameGrid: Equatable {
    let framesPerSegment: Int
    /// Grid frames a frame may be placed ahead of its real time.
    static let maxLead = 1.0
    /// At most this many boundary repeats before one frame (longer gaps do not happen while the
    /// pipeline repeats the last frame; this only bounds the work).
    static let maxFillers = 4
    private(set) var lastIndex: Int64?

    init(framesPerSegment: Int) {
        self.framesPerSegment = max(1, framesPerSegment)
    }

    struct Placement: Equatable {
        /// Grid index for the frame.
        var index: Int64
        /// Segment-boundary indices to fill with the previous frame first (ascending, all < index).
        var fillers: [Int64] = []
    }

    /// Where a frame whose real time is `exactIndex` grid frames after the session start goes,
    /// or nil to drop it (out of order, or no free slot near its time).
    func place(exactIndex: Double) -> Placement? {
        guard exactIndex.isFinite, abs(exactIndex) < 1e12 else { return nil }
        let nearest = Int64(exactIndex.rounded())
        guard let last = lastIndex else {
            return nearest >= 0 ? Placement(index: nearest) : nil
        }
        let index = max(nearest, last + 1)
        guard Double(index) - exactIndex <= Self.maxLead else { return nil }
        let step = Int64(framesPerSegment)
        var fillers: [Int64] = []
        var boundary = (last / step + 1) * step
        while boundary < index, fillers.count < Self.maxFillers {
            fillers.append(boundary)
            boundary += step
        }
        return Placement(index: index, fillers: fillers)
    }

    /// Records a frame the encoder took at `index`.
    mutating func didAppend(_ index: Int64) {
        lastIndex = max(lastIndex ?? index, index)
    }
}
