import AVFoundation
import CoreMedia
import ImageIO
import ReplayKit

/// ReplayKit frames -> 720p -> H.264 fMP4 HLS segments in memory -> local HTTP server.
/// All mutable state lives on `queue`.
final class MirrorPipeline: HLSSegmenterDelegate {
    static let preferredPort: UInt16 = 8765
    /// The app waits for this many segments before telling the TV to play.
    static let segmentsBeforeReady = 3

    private let queue = DispatchQueue(label: "com.mirrordrop.pipeline")
    private let status = StatusPublisher()
    private let config: HLSSegmenter.Config
    private let store: StreamStore
    private let token: String
    private var server: HTTPServer?
    private var scaler: FrameScaler?
    private var segmenter: HLSSegmenter?
    private var timer: DispatchSourceTimer?
    private var ipAddress: String?

    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = CMTime.invalid
    private var lastAppendHostSeconds: Double = 0
    /// host clock seconds minus sample timestamp seconds, to timestamp repeated frames on the same timeline.
    private var hostOffset: Double?
    private var paused = false
    private var ticks = 0
    private var peakMB: Double = 0

    init() {
        let includeAudio = AppGroup.defaults?.bool(forKey: AppGroup.includeAudioKey) ?? false
        let config = HLSSegmenter.Config(includeAudio: includeAudio)
        self.config = config
        store = StreamStore(format: .init(width: config.width, height: config.height,
                                          frameRate: Double(config.frameRate),
                                          bandwidth: config.bitRate + (includeAudio ? 128_000 : 0)))
        token = Self.randomToken()
    }

    // MARK: Lifecycle (called by SampleHandler)

    func start() throws {
        guard let ip = NetworkInfo.wifiIPv4() else {
            throw startFailure("Wi-Fi에 연결되어 있지 않아요. Wi-Fi를 켜고 다시 시작하세요.")
        }
        guard let scaler = FrameScaler(width: config.width, height: config.height) else {
            throw startFailure("화면 변환기를 만들 수 없어요.")
        }
        ipAddress = ip
        self.scaler = scaler
        let segmenter = HLSSegmenter(config: config)
        segmenter.delegate = self
        self.segmenter = segmenter

        status.update {
            $0 = BroadcastStatus()
            $0.state = .starting
            $0.startedAt = Date()
            $0.audioEnabled = self.config.includeAudio
        }
        status.log("broadcast started, ip=\(ip), audio=\(config.includeAudio)")

        let server = HTTPServer(router: StreamRouter(token: token), snapshot: { [store] in store.snapshot() })
        server.onReady = { [weak self] port in self?.serverReady(port: port) }
        server.onError = { [weak self] message in self?.status.error(message) }
        server.onRequest = { [weak self] request, client, response in
            self?.status.recordRequest(method: request.method, path: Self.redact(request.path), client: client,
                                       status: response.status, bytes: response.body.count)
        }
        self.server = server
        server.start(preferredPort: Self.preferredPort)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        status.flush(force: true)
    }

    func setPaused(_ value: Bool) {
        queue.async {
            self.paused = value
            self.status.log(value ? "paused" : "resumed")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            server?.stop()
            server = nil
            lastFrame = nil
            status.update { $0.state = .stopped }
            status.log("broadcast finished")
            status.flush(force: true)
            let done = DispatchSemaphore(value: 0)
            segmenter?.finish { done.signal() }
            _ = done.wait(timeout: .now() + 1)
            segmenter = nil
        }
    }

    // MARK: Samples (called on ReplayKit's thread)

    func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let orientation = Self.orientation(of: sampleBuffer)
        queue.sync {
            status.update {
                $0.framesIn += 1
                $0.orientation = orientation.rawValue
            }
            guard !paused, let scaler, time.isValid else { return }
            // Cap at the target frame rate; the encoder does not need more.
            if lastFrameTime.isValid, (time - lastFrameTime).seconds < 0.9 / Double(config.frameRate) {
                status.update { $0.framesSkipped += 1 }
                return
            }
            if hostOffset == nil { hostOffset = Self.hostSeconds() - time.seconds }
            guard let scaled = scaler.scale(pixelBuffer, orientation: orientation) else {
                status.update { $0.framesDropped += 1 }
                return
            }
            lastFrame = scaled
            append(scaled, at: time, repeated: false)
        }
    }

    func handleAppAudio(_ sampleBuffer: CMSampleBuffer) {
        guard config.includeAudio else { return }
        queue.sync {
            status.update { $0.audioSamplesIn += 1 }
            guard !paused else { return }
            segmenter?.appendAudio(sampleBuffer)
        }
    }

    // MARK: Internals (on queue)

    private func append(_ buffer: CVPixelBuffer, at time: CMTime, repeated: Bool) {
        guard let segmenter else { return }
        if segmenter.appendVideo(buffer, at: time) {
            lastFrameTime = time
            lastAppendHostSeconds = Self.hostSeconds()
            status.update {
                $0.framesEncoded += 1
                if repeated { $0.framesRepeated += 1 }
            }
        } else {
            status.update { $0.framesDropped += 1 }
        }
    }

    /// Every 100 ms: repeat the last frame while the screen is static (ReplayKit sends no frames then),
    /// so segments keep coming. Every 500 ms: publish status. Every second: sample memory.
    private func tick() {
        ticks += 1
        let now = Self.hostSeconds()
        if !paused, let lastFrame, let hostOffset, now - lastAppendHostSeconds > 0.25 {
            let time = CMTime(seconds: now - hostOffset, preferredTimescale: 90_000)
            append(lastFrame, at: time, repeated: true)
        }
        if ticks % 10 == 0 {
            let mb = MemoryInfo.physFootprintMB()
            peakMB = max(peakMB, mb)
            let peak = peakMB
            status.update {
                $0.memoryMB = mb
                $0.peakMemoryMB = peak
            }
            if mb > 40, ticks % 50 == 0 { status.error(String(format: "memory high: %.1f MB", mb)) }
        }
        if ticks % 5 == 0 { status.flush() }
    }

    private func serverReady(port: UInt16) {
        guard let ipAddress else { return }
        let url = "http://\(ipAddress):\(port)/\(token)/\(HLSPlaylist.masterName)"
        status.update { $0.url = url }
        status.log("server ready on port \(port)")
        status.flush(force: true)
    }

    // MARK: HLSSegmenterDelegate (writer queue)

    func segmenter(_ segmenter: HLSSegmenter, didOutputInitSegment data: Data) {
        store.setInitSegment(data)
        let codecs = store.currentCodecs
        status.update { $0.codecs = codecs }
        status.log("init segment \(data.count) bytes, codecs=\(codecs ?? "?")")
    }

    func segmenter(_ segmenter: HLSSegmenter, didOutputSegment data: Data, duration: Double) {
        store.addSegment(duration: duration, data: data)
        let count = store.segmentCount
        status.update {
            $0.segmentsProduced += 1
            $0.segmentsInWindow = count
            $0.lastSegmentDuration = duration
            $0.lastSegmentBytes = data.count
            if $0.segmentsProduced >= Self.segmentsBeforeReady, $0.state == .starting { $0.state = .streaming }
        }
        if count == Self.segmentsBeforeReady { status.flush(force: true) }
    }

    func segmenter(_ segmenter: HLSSegmenter, didFail message: String) {
        status.error(message)
        status.update { $0.state = .failed }
        status.flush(force: true)
    }

    // MARK: Helpers

    private func startFailure(_ message: String) -> NSError {
        status.update {
            $0 = BroadcastStatus()
            $0.state = .failed
        }
        status.error(message)
        status.flush(force: true)
        return NSError(domain: "MirrorDrop", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber
        return value.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
    }

    private static func hostSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private static func randomToken() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt32.random(in: 0...255)) }.joined()
    }

    /// The token is a per-broadcast secret; keep it out of the diagnostics log.
    private static func redact(_ path: String) -> String {
        let parts = path.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? "/…/" + parts[1] : path
    }
}
