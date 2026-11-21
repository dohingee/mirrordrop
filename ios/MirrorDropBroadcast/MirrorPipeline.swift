import AVFoundation
import CoreMedia
import ImageIO
import Network
import ReplayKit

/// ReplayKit frames -> 720p -> H.264 fMP4 HLS segments in memory -> local HTTP server.
/// App sound -> AudioTrack (48 kHz stereo, silence when missing or when the output is the phone) -> AAC
/// in the same segments. All mutable state lives on `queue`.
final class MirrorPipeline: HLSSegmenterDelegate {
    static let preferredPort: UInt16 = 8765

    private let queue = DispatchQueue(label: "com.mirrordrop.pipeline")
    private let status = StatusPublisher()
    private let config: HLSSegmenter.Config
    private let preset: LatencyPreset
    private let store: StreamStore
    private let token: String
    private var server: HTTPServer?
    private var scaler: FrameScaler?
    private var segmenter: HLSSegmenter?
    private var audio: AudioTrack?
    private var observingAudioOutput = false
    private var timer: DispatchSourceTimer?
    /// "TV 보내기가 멈췄어요" notification: fires if the extension dies without a callback, or when the
    /// broadcast finished because the iPhone locked (StopAlertArmer). Its lines are published at once:
    /// after the broadcast finished no tick flushes the status any more.
    private lazy var stopAlert = StopAlertArmer(queue: queue, log: { [status] in
        status.log($0)
        status.flush(force: true)
    })
    private var pathMonitor: NWPathMonitor?
    private var address: StreamAddress
    /// When the published URL gets a new `urlRevision` (the app re-sends a new revision to the TV).
    private var revision = StreamURLRevision()
    private var running = false
    /// Host-clock times of recent encoder replacements, to give up if the writer keeps failing.
    private var recoveryTimes: [Double] = []
    private static let maxRecoveriesPerMinute = 3
    private static var noWiFiMessage: String { String(localized: "Wi-Fi 연결이 끊겼어요. Wi-Fi가 다시 연결되면 새 주소로 이어서 보냅니다.") }

    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = CMTime.invalid
    private var lastAppendHostSeconds: Double = 0
    /// host clock seconds minus sample timestamp seconds, to timestamp repeated frames on the same timeline.
    private var hostOffset: Double?
    private var paused = false
    private var ticks = 0
    private var peakMB: Double = 0

    init() {
        let preset = LatencyPreset.load()
        self.preset = preset
        let config = HLSSegmenter.Config(segmentSeconds: preset.segmentSeconds)
        self.config = config
        store = StreamStore(format: .init(width: config.width, height: config.height,
                                          frameRate: Double(config.frameRate),
                                          bandwidth: config.bitRate + (config.includeAudio ? AudioTrackFormat.bitRate : 0)),
                            playlistWindow: preset.playlistWindow,
                            storedSegments: preset.storedSegments,
                            startOffset: preset.startOffset,
                            segmentSeconds: preset.segmentSeconds)
        token = Self.randomToken()
        address = StreamAddress(token: token)
    }

    // MARK: Lifecycle (called by SampleHandler)

    func start() throws {
        guard let ip = NetworkInfo.wifiIPv4() else {
            // Shown by iOS in its broadcast-ended alert: localized (MirrorDropBroadcast/Localizable.xcstrings).
            throw startFailure(String(localized: "Wi-Fi에 연결되어 있지 않아요. Wi-Fi를 켜고 다시 시작하세요."))
        }
        guard let scaler = FrameScaler(width: config.width, height: config.height) else {
            throw startFailure(String(localized: "화면 변환기를 만들 수 없어요."))
        }
        let output = AudioOutput.load()
        queue.sync {
            running = true
            address.update(ip: ip)
            self.scaler = scaler
            segmenter = makeSegmenter()
            audio = AudioTrack(output: output) { [status] message in
                if message.hasPrefix("ERROR ") {
                    status.error(String(message.dropFirst(6)))
                } else {
                    status.log(message)
                }
            }
        }

        status.update {
            $0 = BroadcastStatus()
            $0.state = .starting
            $0.startedAt = Date()
            $0.audioOutput = output.code
            $0.latencyPreset = self.preset.code
        }
        observeAudioOutput()
        let start = preset.startOffset.map { String($0) } ?? "-"
        status.log("broadcast started, ip=\(ip), audio=\(output.code), preset=\(preset.code) "
                   + "(segment \(preset.segmentSeconds)s, window \(preset.playlistWindow), "
                   + "stored \(preset.storedSegments), start \(start))")

        let server = HTTPServer(router: StreamRouter(token: token), snapshot: { [store] in store.snapshot() })
        server.onReady = { [weak self] port in
            self?.queue.async { self?.serverReady(port: port) }
        }
        server.onError = { [weak self] message in self?.status.error(message) }
        server.onRequest = { [weak self] request, client, response in
            let now = Self.hostSeconds()
            self?.status.recordRequest(method: request.method, path: Self.redact(request.path), client: client,
                                       status: response.status, bytes: response.body.count)
            // The path is only classified there (kind and number), never stored.
            self?.status.update {
                $0.startup.recordRequest(method: request.method, path: request.path, status: response.status,
                                         body: response.body, now: now)
            }
        }
        self.server = server
        server.start(preferredPort: Self.preferredPort)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tick() }
        // Wi-Fi switched, lost or back: re-read the address at once (tick() also polls every 2 s,
        // because the path can be reported before the new IPv4 address is assigned).
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in self?.refreshAddress() }
        queue.sync {
            self.timer = timer
            pathMonitor = monitor
            stopAlert.start()
        }
        timer.resume()
        monitor.start(queue: queue)
        status.flush(force: true)
    }

    func setPaused(_ value: Bool) {
        queue.async {
            self.paused = value
            self.status.log(value ? "paused" : "resumed")
        }
    }

    func stop() {
        stopObservingAudioOutput()
        queue.sync {
            running = false
            // First, so the alert is decided even if the process ends soon after this call: removed for a
            // user stop, scheduled when the iPhone is locked (logs "broadcast finished (locked=…)").
            stopAlert.finish()
            timer?.cancel()
            timer = nil
            pathMonitor?.cancel()
            pathMonitor = nil
            server?.stop()
            server = nil
            lastFrame = nil
            status.update { $0.state = .stopped }
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
        let now = Self.hostSeconds()
        queue.sync {
            status.update {
                $0.framesIn += 1
                $0.orientation = orientation.rawValue
                $0.startup.recordFrame(.input, now: now)
            }
            guard !paused, let scaler, time.isValid else { return }
            // Cap at the target frame rate; the encoder does not need more.
            if lastFrameTime.isValid, (time - lastFrameTime).seconds < 0.9 / Double(config.frameRate) {
                status.update { $0.framesSkipped += 1 }
                return
            }
            if hostOffset == nil { hostOffset = Self.hostSeconds() - time.seconds }
            guard let scaled = scaler.scale(pixelBuffer, orientation: orientation) else {
                status.update {
                    $0.framesDropped += 1
                    $0.startup.recordFrame(.dropped, now: now)
                }
                return
            }
            lastFrame = scaled
            append(scaled, at: time, repeated: false)
        }
    }

    func handleAppAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            // Before the first video frame there is no timeline to place sound on yet.
            guard let audio, let segmenter, let hostOffset else { return }
            let now = Self.hostSeconds()
            audio.handleReal(sampleBuffer, videoNow: now - hostOffset, hostNow: now, paused: paused,
                             segmenter: segmenter)
        }
    }

    deinit {
        stopObservingAudioOutput()
    }

    // MARK: Internals (on queue)

    private func makeSegmenter() -> HLSSegmenter {
        let segmenter = HLSSegmenter(config: config)
        segmenter.delegate = self
        return segmenter
    }

    private func append(_ buffer: CVPixelBuffer, at time: CMTime, repeated: Bool) {
        guard let segmenter else { return }
        if segmenter.appendVideo(buffer, at: time) {
            lastFrameTime = time
            let now = Self.hostSeconds()
            lastAppendHostSeconds = now
            status.update {
                $0.framesEncoded += 1
                if repeated { $0.framesRepeated += 1 }
                $0.startup.recordFrame(.encoded(repeated: repeated), now: now)
            }
        } else {
            let now = Self.hostSeconds()
            status.update {
                $0.framesDropped += 1
                $0.startup.recordFrame(.dropped, now: now)
            }
        }
    }

    /// Every 100 ms: repeat the last frame while the screen is static (ReplayKit sends no frames then),
    /// so segments keep coming. Every 500 ms: publish status. Every second: sample memory.
    /// Every 2 s: check the Wi-Fi address and push the stop alert out again (StopAlertArmer).
    /// The last frame is repeated while paused too: a gap in the video would come out as one long
    /// segment, which would push EXT-X-TARGETDURATION up for the rest of the broadcast (see
    /// TargetDuration) and leave the TV without new segments. The TV keeps showing the frozen frame.
    private func tick() {
        ticks += 1
        let now = Self.hostSeconds()
        if let lastFrame, let hostOffset, now - lastAppendHostSeconds > 0.25 {
            let time = CMTime(seconds: now - hostOffset, preferredTimescale: 90_000)
            append(lastFrame, at: time, repeated: true)
        }
        // Silence while no app sound comes, so the writer never waits for the audio track.
        if let audio, let segmenter, let hostOffset {
            audio.fill(videoNow: now - hostOffset, hostNow: now, segmenter: segmenter)
        }
        if ticks % 5 == 0 {
            // Fallback for the Darwin notification (both are cheap).
            refreshAudioOutput()
            publishAudioStats(resetRecentPeak: ticks % 10 == 0)
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
        if ticks % 20 == 0 { refreshAddress() }
        stopAlert.tick()
        if ticks % 5 == 0 { status.flush() }
    }

    /// Reads the "소리 나오는 곳" setting; a change applies to the next audio buffer, no restart.
    private func refreshAudioOutput() {
        guard running, let audio else { return }
        let output = AudioOutput.load()
        guard output != audio.output else { return }
        status.log("audio output \(audio.output.code) -> \(output.code)")
        audio.output = output
        status.update { $0.audioOutput = output.code }
        status.flush(force: true)
    }

    /// `resetRecentPeak` (once a second) moves the recent peak into the status and starts a new one.
    private func publishAudioStats(resetRecentPeak: Bool) {
        guard let audio else { return }
        let stats = audio.stats
        let recent = resetRecentPeak ? audio.takeRecentPeak() : nil
        status.update {
            $0.audioSamplesIn = stats.samplesIn
            $0.audioSilentFrames = stats.silentFrames
            $0.audioRealFrames = stats.realFrames
            $0.audioDroppedFrames = stats.droppedFrames
            $0.audioPeakMax = Double(stats.peakMax)
            $0.audioSourceFormat = stats.sourceFormat
            if let recent { $0.audioPeakRecent = Double(recent) }
        }
    }

    /// The app posts `AppGroup.audioOutputNotification` when the setting changes.
    private func observeAudioOutput() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let pipeline = Unmanaged<MirrorPipeline>.fromOpaque(observer).takeUnretainedValue()
                pipeline.queue.async { pipeline.refreshAudioOutput() }
            },
            AppGroup.audioOutputNotification as CFString, nil, .deliverImmediately)
        observingAudioOutput = true
    }

    private func stopObservingAudioOutput() {
        guard observingAudioOutput else { return }
        observingAudioOutput = false
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
    }

    private func serverReady(port: UInt16) {
        guard running else { return }
        status.log("server ready on port \(port)")
        if address.update(port: port) { publishAddress() }
    }

    private func refreshAddress() {
        guard running else { return }
        if address.update(ip: NetworkInfo.wifiIPv4()) { publishAddress() }
    }

    /// Writes the current URL (or the reason there is none) to the status. The token stays out of the log.
    /// `urlRevision` rises only for a new URL text or after an outage of 3 s or more (StreamURLRevision):
    /// a short blip, e.g. an empty IP read while the screen locks, must not make the app re-load the TV.
    private func publishAddress() {
        let url = address.url
        let ip = address.ip
        let raised = revision.update(url: url, now: Self.hostSeconds())
        let rev = revision.revision
        status.update {
            $0.url = url
            $0.urlRevision = rev
            $0.networkIssue = ip == nil ? Self.noWiFiMessage : nil
        }
        if let ip {
            let port = address.port.map { String($0) } ?? "-"
            let change = url == nil ? "" : raised ? " (new)" : " (same, TV keeps playing)"
            status.log("stream address ip=\(ip), port=\(port), rev \(rev)\(change)")
        } else {
            status.error("no Wi-Fi IPv4 address; waiting for Wi-Fi")
        }
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
        let targetBefore = store.targetDuration
        // Before the store, so no TV request for this segment can be timed earlier than it.
        let madeAt = Self.hostSeconds()
        let segment = store.addSegment(duration: duration, data: data)
        let target = store.targetDuration
        if target > targetBefore {
            status.error(String(format: "segment %.3f s raised the target duration %d -> %d s",
                                duration, targetBefore, target))
        }
        let count = store.segmentCount
        // The app waits for this many segments before telling the TV to play.
        let ready = preset.segmentsBeforeReady
        status.update {
            $0.segmentsProduced += 1
            $0.segmentsInWindow = count
            $0.lastSegmentDuration = duration
            $0.lastSegmentBytes = data.count
            $0.startup.recordSegment(sequence: segment.sequence, duration: duration, bytes: data.count, now: madeAt)
            if $0.segmentsProduced >= ready, $0.state == .starting { $0.state = .streaming }
        }
        if count == ready { status.flush(force: true) }
    }

    /// Called on the pipeline queue (from an append). The replacement is deferred so the current
    /// append call finishes first.
    func segmenter(_ segmenter: HLSSegmenter, didFail message: String) {
        status.error(message)
        status.flush(force: true)
        queue.async { [weak self, weak segmenter] in
            guard let self, let segmenter else { return }
            self.replaceSegmenter(segmenter)
        }
    }

    func segmenter(_ segmenter: HLSSegmenter, didWarn message: String) {
        status.error(message)
    }

    /// A failed AVAssetWriter cannot be restarted, so a new one takes over. Its segments get
    /// EXT-X-DISCONTINUITY and a new init segment (StreamStore.beginNewEncoder); the URL stays the
    /// same, so the TV can keep playing. Gives up (state .failed) if the writer keeps failing.
    private func replaceSegmenter(_ failed: HLSSegmenter) {
        guard running, segmenter === failed else { return }
        failed.delegate = nil
        segmenter = nil
        let now = Self.hostSeconds()
        recoveryTimes = recoveryTimes.filter { now - $0 < 60 } + [now]
        guard recoveryTimes.count <= Self.maxRecoveriesPerMinute else {
            status.error("encoder keeps failing; giving up")
            status.update { $0.state = .failed }
            status.flush(force: true)
            return
        }
        store.beginNewEncoder()
        lastFrameTime = .invalid
        segmenter = makeSegmenter()
        status.log("encoder restarted (\(recoveryTimes.count) in the last minute)")
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
        HostClock.now()
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
