import Foundation

/// Thread-safe holder of the init segment(s) and the newest media segments.
/// Written from the AVAssetWriter delegate queue, read from the HTTP server queue.
final class StreamStore {
    struct Format {
        var width: Int
        var height: Int
        var frameRate: Double
        var bandwidth: Int
    }

    let playlistWindow: Int
    let startOffset: Double?
    let segmentSeconds: Double
    let format: Format
    private let lock = NSLock()
    private var ring: SegmentRing
    private var target: TargetDuration
    private var initSegment: Data?
    private var initVersion = 0
    /// Init segments of earlier encoders, kept only while a stored segment still needs them.
    private var olderInitSegments: [Int: Data] = [:]
    private var pendingDiscontinuity = false
    private var codecs: String?

    init(format: Format,
         playlistWindow: Int = LatencyPreset.default.playlistWindow,
         storedSegments: Int = LatencyPreset.default.storedSegments,
         startOffset: Double? = LatencyPreset.default.startOffset,
         segmentSeconds: Double = LatencyPreset.default.segmentSeconds) {
        precondition(storedSegments >= playlistWindow)
        self.format = format
        self.playlistWindow = playlistWindow
        self.startOffset = startOffset
        self.segmentSeconds = segmentSeconds
        ring = SegmentRing(capacity: storedSegments)
        target = TargetDuration(segmentSeconds: segmentSeconds)
    }

    func setInitSegment(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        initSegment = data
        codecs = HLSPlaylist.codecs(fromInitSegment: data) ?? codecs
    }

    /// Called when the encoder is replaced (after a writer failure): the next segment starts a new
    /// timeline with a new init segment, so it gets EXT-X-DISCONTINUITY and a new EXT-X-MAP.
    func beginNewEncoder() {
        lock.lock(); defer { lock.unlock() }
        if let initSegment { olderInitSegments[initVersion] = initSegment }
        initSegment = nil
        initVersion += 1
        pendingDiscontinuity = ring.nextSequence > 0
        pruneInitSegments()
    }

    @discardableResult
    func addSegment(duration: Double, data: Data) -> MediaSegment {
        lock.lock(); defer { lock.unlock() }
        let segment = ring.append(duration: duration, data: data,
                                  discontinuity: pendingDiscontinuity, initVersion: initVersion)
        pendingDiscontinuity = false
        target.record(duration)
        pruneInitSegments()
        return segment
    }

    var segmentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.items.count
    }

    var storedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.totalBytes + (initSegment?.count ?? 0) + olderInitSegments.values.reduce(0) { $0 + $1.count }
    }

    var currentCodecs: String? {
        lock.lock(); defer { lock.unlock() }
        return codecs
    }

    /// EXT-X-TARGETDURATION for this stream (only ever goes up, see `TargetDuration`).
    var targetDuration: Int {
        lock.lock(); defer { lock.unlock() }
        return target.value
    }

    func snapshot() -> StreamSnapshot {
        lock.lock(); defer { lock.unlock() }
        let window = HLSPlaylist.windowCount(playlistWindow: playlistWindow, target: target, stored: ring.capacity)
        return StreamSnapshot(
            initSegment: initSegment,
            playlistSegments: ring.latest(window),
            storedSegments: ring.items,
            codecs: codecs,
            bandwidth: format.bandwidth,
            width: format.width,
            height: format.height,
            frameRate: format.frameRate,
            startOffset: startOffset,
            targetDuration: target.value,
            initVersion: initVersion,
            olderInitSegments: olderInitSegments)
    }

    /// Call with the lock held.
    private func pruneInitSegments() {
        guard !olderInitSegments.isEmpty else { return }
        let needed = Set(ring.items.map(\.initVersion))
        olderInitSegments = olderInitSegments.filter { needed.contains($0.key) }
    }
}
