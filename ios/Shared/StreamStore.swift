import Foundation

/// Thread-safe holder of the init segment and the newest media segments.
/// Written from the AVAssetWriter delegate queue, read from the HTTP server queue.
final class StreamStore {
    struct Format {
        var width: Int
        var height: Int
        var frameRate: Double
        var bandwidth: Int
    }

    let playlistWindow: Int
    let format: Format
    private let lock = NSLock()
    private var ring: SegmentRing
    private var initSegment: Data?
    private var codecs: String?

    init(format: Format, playlistWindow: Int = 4, storedSegments: Int = 7) {
        precondition(storedSegments >= playlistWindow)
        self.format = format
        self.playlistWindow = playlistWindow
        ring = SegmentRing(capacity: storedSegments)
    }

    func setInitSegment(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        initSegment = data
        codecs = HLSPlaylist.codecs(fromInitSegment: data)
    }

    @discardableResult
    func addSegment(duration: Double, data: Data) -> MediaSegment {
        lock.lock(); defer { lock.unlock() }
        return ring.append(duration: duration, data: data)
    }

    var segmentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.items.count
    }

    var storedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.totalBytes + (initSegment?.count ?? 0)
    }

    var currentCodecs: String? {
        lock.lock(); defer { lock.unlock() }
        return codecs
    }

    func snapshot() -> StreamSnapshot {
        lock.lock(); defer { lock.unlock() }
        return StreamSnapshot(
            initSegment: initSegment,
            playlistSegments: ring.latest(playlistWindow),
            storedSegments: ring.items,
            codecs: codecs,
            bandwidth: format.bandwidth,
            width: format.width,
            height: format.height,
            frameRate: format.frameRate)
    }
}
