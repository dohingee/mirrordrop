import Foundation

struct MediaSegment: Equatable {
    let sequence: Int
    let duration: Double
    let data: Data
    /// True for the first segment of a new encoder after a recovery (EXT-X-DISCONTINUITY before it).
    var discontinuity = false
    /// RFC 8216 discontinuity sequence number: discontinuities up to and including this segment.
    var discontinuitySequence = 0
    /// Which init segment (EXT-X-MAP) this segment needs; changes only after a discontinuity.
    var initVersion = 0
    /// Seconds from the first segment of the stream to this one's start (set by SegmentRing), so
    /// EXTINF can be rounded without the rounding piling up (`HLSPlaylist.extinfSeconds`).
    var start: Double? = nil
}

/// Keeps only the newest `capacity` segments so memory stays bounded.
struct SegmentRing {
    let capacity: Int
    private(set) var items: [MediaSegment] = []
    private(set) var nextSequence = 0
    private(set) var discontinuityCount = 0
    /// Sum of all appended durations (the next segment's `start`).
    private(set) var elapsed: Double = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    @discardableResult
    mutating func append(duration: Double, data: Data, discontinuity: Bool = false, initVersion: Int = 0) -> MediaSegment {
        if discontinuity { discontinuityCount += 1 }
        let segment = MediaSegment(sequence: nextSequence, duration: duration, data: data,
                                   discontinuity: discontinuity, discontinuitySequence: discontinuityCount,
                                   initVersion: initVersion, start: elapsed)
        if duration.isFinite, duration > 0 { elapsed += duration }
        nextSequence += 1
        items.append(segment)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
        return segment
    }

    func segment(sequence: Int) -> MediaSegment? {
        items.first { $0.sequence == sequence }
    }

    func latest(_ count: Int) -> [MediaSegment] {
        Array(items.suffix(max(0, count)))
    }

    var totalBytes: Int { items.reduce(0) { $0 + $1.data.count } }
}

/// EXT-X-TARGETDURATION for one live stream.
/// RFC 8216 6.2.1 says the value must not change, and 4.3.3.1 says every EXTINF rounded to the
/// nearest integer must be <= it. Both cannot hold if a segment comes out much longer than planned
/// (encoder stall), so the value starts from the configured segment length (1 for 0.5 s and 1 s,
/// the lowest possible, because players stay about three targets behind the live edge) and is only
/// ever raised, never lowered. A one-time rise breaks 6.2.1 once; going down again would break it
/// again, and starting higher "just in case" would add delay to every broadcast.
struct TargetDuration: Equatable {
    /// The value at broadcast start, from the configured segment length.
    let initial: Int
    private(set) var value: Int

    init(segmentSeconds: Double) {
        initial = Self.rounded(segmentSeconds)
        value = initial
    }

    /// Nearest, not up (see `HLSPlaylist.targetDuration`).
    static func rounded(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return max(1, Int(seconds.rounded(.toNearestOrAwayFromZero)))
    }

    /// Returns true when the segment forced the value up.
    @discardableResult
    mutating func record(_ segmentDuration: Double) -> Bool {
        let needed = Self.rounded(segmentDuration)
        guard needed > value else { return false }
        value = needed
        return true
    }
}

enum HLSPlaylist {
    static let masterName = "live.m3u8"
    static let mediaName = "media.m3u8"
    static let initName = "init.mp4"

    /// Version 0 keeps the original name; later encoders (after a recovery) get init1.mp4, init2.mp4, …
    /// so a TV that cached an older init segment never mixes it with new segments.
    static func initSegmentName(version: Int) -> String { version == 0 ? initName : "init\(version).mp4" }

    static func initVersion(fromName name: String) -> Int? {
        if name == initName { return 0 }
        guard name.hasPrefix("init"), name.hasSuffix(".mp4") else { return nil }
        let digits = name.dropFirst(4).dropLast(4)
        guard !digits.isEmpty, digits.first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// How many of the newest segments to list. While the target duration is at its starting value
    /// this is exactly the preset window: every preset already covers 3 x that target (RFC 8216 6.2.2,
    /// checked in LatencyPresetTests), and listing more would make the default receiver (which seems
    /// to start near the top of the playlist) start further behind. Only if the target was raised does
    /// the window grow in proportion, capped at what is already stored (no extra memory), to stay as
    /// close to the 3 x target rule as the store allows.
    static func windowCount(playlistWindow: Int, target: TargetDuration, stored: Int) -> Int {
        guard target.value > target.initial else { return max(1, min(playlistWindow, stored)) }
        let scaled = (playlistWindow * target.value + target.initial - 1) / target.initial
        return max(1, min(scaled, stored))
    }

    static func segmentName(_ sequence: Int) -> String { "seg\(sequence).m4s" }

    static func sequence(fromSegmentName name: String) -> Int? {
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        let digits = name.dropFirst(3).dropLast(4)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// EXT-X-TARGETDURATION must be >= every EXTINF rounded to the nearest integer (RFC 8216 4.3.3.1).
    /// Nearest, not up: AVAssetWriter cuts at the first keyframe after the interval, so 1 s segments
    /// come out a little longer (1.033 s). Rounding up made the target 2, and players start about
    /// three target durations behind the live edge, so the delay doubled (about 6 s on a real TV).
    static func targetDuration(_ segments: [MediaSegment]) -> Int {
        TargetDuration.rounded(segments.map(extinfSeconds).max() ?? 1)
    }

    /// The EXTINF value (milliseconds). Grid segments are 16/30 s = 0.53333… s, so rounding each
    /// duration to 0.533 would make the playlist fall 1 ms behind the media every 3 segments, and a
    /// player that places segments by summed EXTINF (Shaka in segments mode moves its timestamp
    /// offset once they disagree by 1 ms) would shift the sound a little again and again. So the
    /// segment's end and start on the stream timeline are rounded instead: the listed durations add
    /// up to the real time within 1 ms however long the stream runs. Without `start`, the duration.
    static func extinfSeconds(_ segment: MediaSegment) -> Double {
        guard let start = segment.start, start.isFinite, segment.duration.isFinite else { return segment.duration }
        let milliseconds = ((start + segment.duration) * 1000).rounded() - (start * 1000).rounded()
        return milliseconds / 1000
    }

    /// Live (sliding window) media playlist. No EXT-X-ENDLIST.
    /// `startOffset` adds EXT-X-START (negative: seconds before the playlist end) as a hint to the
    /// player where to begin; players that ignore it are unaffected. Nil keeps the output unchanged.
    /// `targetDuration` is the stream's fixed value (`TargetDuration`); it is never written lower than
    /// the listed segments need.
    static func media(_ segments: [MediaSegment], startOffset: Double? = nil, targetDuration: Int? = nil) -> String {
        let target = max(targetDuration ?? 0, Self.targetDuration(segments))
        let first = segments.first
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if let startOffset {
            lines.append("#EXT-X-START:TIME-OFFSET=" + String(format: "%.1f", startOffset) + ",PRECISE=NO")
        }
        lines += [
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(first?.sequence ?? 0)",
        ]
        // The first listed segment's own discontinuity is carried by this number instead of a tag.
        if let first, first.discontinuitySequence > 0 {
            lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(first.discontinuitySequence)")
        }
        var mapVersion = first?.initVersion ?? 0
        lines.append("#EXT-X-MAP:URI=\"\(initSegmentName(version: mapVersion))\"")
        for (index, segment) in segments.enumerated() {
            if index > 0, segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            if segment.initVersion != mapVersion {
                mapVersion = segment.initVersion
                lines.append("#EXT-X-MAP:URI=\"\(initSegmentName(version: mapVersion))\"")
            }
            lines.append("#EXTINF:" + String(format: "%.3f", extinfSeconds(segment)) + ",")
            lines.append(segmentName(segment.sequence))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func master(bandwidth: Int, codecs: String?, width: Int, height: Int, frameRate: Double) -> String {
        var attributes = ["BANDWIDTH=\(bandwidth)"]
        if let codecs { attributes.append("CODECS=\"\(codecs)\"") }
        attributes.append("RESOLUTION=\(width)x\(height)")
        attributes.append("FRAME-RATE=" + String(format: "%.3f", frameRate))
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-STREAM-INF:" + attributes.joined(separator: ","),
            mediaName,
        ].joined(separator: "\n") + "\n"
    }

    /// RFC 6381 codec string read from the init segment ("avc1.PPCCLL", plus "mp4a.40.2" when audio is present).
    static func codecs(fromInitSegment data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let avcC = find(Array("avcC".utf8), in: bytes) else { return nil }
        // avcC box payload: configurationVersion, profile, compatibility, level.
        let start = avcC + 4
        guard start + 4 <= bytes.count, bytes[start] == 1 else { return nil }
        var result = String(format: "avc1.%02x%02x%02x",
                            UInt32(bytes[start + 1]), UInt32(bytes[start + 2]), UInt32(bytes[start + 3]))
        if find(Array("mp4a".utf8), in: bytes) != nil {
            result += ",mp4a.40.2"
        }
        return result
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if Array(haystack[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}
