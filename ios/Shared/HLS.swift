import Foundation

struct MediaSegment: Equatable {
    let sequence: Int
    let duration: Double
    let data: Data
}

/// Keeps only the newest `capacity` segments so memory stays bounded.
struct SegmentRing {
    let capacity: Int
    private(set) var items: [MediaSegment] = []
    private(set) var nextSequence = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    @discardableResult
    mutating func append(duration: Double, data: Data) -> MediaSegment {
        let segment = MediaSegment(sequence: nextSequence, duration: duration, data: data)
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

enum HLSPlaylist {
    static let masterName = "live.m3u8"
    static let mediaName = "media.m3u8"
    static let initName = "init.mp4"

    static func segmentName(_ sequence: Int) -> String { "seg\(sequence).m4s" }

    static func sequence(fromSegmentName name: String) -> Int? {
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        let digits = name.dropFirst(3).dropLast(4)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// EXT-X-TARGETDURATION must be >= every EXTINF rounded to the nearest integer.
    static func targetDuration(_ segments: [MediaSegment]) -> Int {
        let longest = segments.map(\.duration).max() ?? 1
        return max(1, Int(longest.rounded(.up)))
    }

    /// Live (sliding window) media playlist. No EXT-X-ENDLIST.
    static func media(_ segments: [MediaSegment]) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-TARGETDURATION:\(targetDuration(segments))",
            "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.sequence ?? 0)",
            "#EXT-X-MAP:URI=\"\(initName)\"",
        ]
        for segment in segments {
            lines.append("#EXTINF:" + String(format: "%.3f", segment.duration) + ",")
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
