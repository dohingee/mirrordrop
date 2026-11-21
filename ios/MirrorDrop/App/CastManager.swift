import Foundation
import GoogleCast

/// Wraps the Google Cast sender SDK: discovery/session state, loading media, receiver status and SDK logs.
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()
    /// Default Media Receiver. Must match the _CC1AD845._googlecast._tcp entry in NSBonjourServices.
    static let receiverAppID = "CC1AD845"

    enum SegmentFormat { case fmp4, ts }

    /// GCKCastState in our own terms, so views do not need to import GoogleCast.
    enum Connection { case noDevices, notConnected, connecting, connected }

    /// What the TV is doing with the last media we sent, simplified for the main screen.
    enum TVPlayback { case none, loading, playing, paused, ended, failed }

    @Published private(set) var stateText = "준비 중"
    @Published private(set) var connection = Connection.notConnected
    @Published private(set) var isConnected = false
    /// When discovery started reporting "no devices" (nil otherwise). Discovery needs a few seconds
    /// after launch, so the main screen waits a little before showing the "TV not found" help.
    @Published private(set) var noDevicesSince: Date?
    @Published private(set) var deviceName: String?
    @Published private(set) var mediaText = "-"
    @Published private(set) var tvPlayback = TVPlayback.none
    /// Mirror stream URL last sent to the current session; nil after a disconnect, so the mirror
    /// is sent again when the session comes back (new session, resume, or reconnect).
    @Published private(set) var loadedMirrorURL: URL?
    /// `BroadcastStatus.urlRevision` of the mirror last sent. The same URL text can come back after
    /// a Wi-Fi outage with a new revision; the TV has to be asked again then.
    private(set) var loadedMirrorRevision: Int?
    @Published private(set) var lastError: String?
    @Published private(set) var events: [String] = []
    /// Receiver's live seekable range end and playback position (seconds), or nil when unknown.
    @Published private(set) var liveLag: (end: Double, position: Double)?
    /// TV (Cast device) volume 0...1 and mute, as last reported by the device; nil when not connected.
    @Published private(set) var tvVolume: Float?
    @Published private(set) var tvMuted = false
    /// "시작 기록" TV side: player states and live lag for 30 s after the last mirror load request.
    @Published private(set) var startupPlayback: PlaybackTrace?
    private(set) var sdkLog: [String] = []
    /// Per-broadcast secret path parts of every mirror URL sent, so diagnostics can hide them.
    private(set) var mirrorTokens: Set<String> = []
    private var isSetUp = false
    private weak var observedClient: GCKRemoteMediaClient?
    private var loadRequest: GCKRequest? {
        didSet { isLoadPending = loadRequest != nil }
    }
    /// A play request was sent and the TV has not answered yet (MirrorCastCoordinator keeps the app
    /// awake in the background until it has).
    @Published private(set) var isLoadPending = false
    private var lagTimer: Timer?

    #if MD_DEMO
    /// App Store screenshots only (App/DemoMode.swift); never compiled into the shipped app.
    private var isDemo = false

    /// Shows a connected TV, and for `.sending` the mirror playing on it, without a Cast device.
    func applyDemo(_ demo: DemoMode) {
        isDemo = true
        stateText = "연결됨"
        connection = .connected
        isConnected = true
        noDevicesSince = nil
        deviceName = DemoMode.tvName
        tvVolume = 0.35
        tvMuted = false
        if demo == .sending {
            loadedMirrorURL = DemoMode.streamURL
            loadedMirrorRevision = 1
            tvPlayback = .playing
            mediaText = "재생 중"
        }
    }
    #endif

    func setUp() {
        guard !isSetUp else { return }
        isSetUp = true
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: Self.receiverAppID))
        // Off: outside this app the side buttons can only change the phone volume (iOS gives no way
        // to route them to the TV), so they do the same inside the app too. TV volume: the slider
        // on the main screen or the TV remote. (2026-11-21, users mostly press the side buttons.)
        options.physicalVolumeButtonsWillControlDeviceVolume = false
        // Default YES: the SDK suspends the session as soon as the app goes to the background, so a
        // play request sent from a background task (MirrorCastCoordinator, user left the app right
        // after starting) would find no session. Once the app is really suspended the connection
        // drops anyway and the SDK resumes or reconnects when the app comes back.
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKLogger.sharedInstance().delegate = self

        let context = GCKCastContext.sharedInstance()
        context.sessionManager.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(castStateDidChange),
                                               name: NSNotification.Name.gckCastStateDidChange, object: context)
        refreshState()
        lagTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLiveLag()
        }
    }

    private var currentSession: GCKCastSession? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession
    }

    /// Sets the TV's own volume (0...1), like the AirPlay volume slider.
    func setTVVolume(_ volume: Float) {
        guard let session = currentSession else { return }
        let value = min(max(volume, 0), 1)
        session.setDeviceVolume(value)
        tvVolume = value
    }

    func setTVMuted(_ muted: Bool) {
        guard let session = currentSession else { return }
        session.setDeviceMuted(muted)
        tvMuted = muted
    }

    private var remoteClient: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    /// Opens the SDK's own device chooser (same dialog as the Cast button).
    func presentDeviceChooser() {
        GCKCastContext.sharedInstance().presentCastDialog()
    }

    /// Asks the connected receiver to play an HLS URL.
    @discardableResult
    func load(url: URL, title: String, live: Bool, format: SegmentFormat) -> Bool {
        guard let client = remoteClient else {
            lastError = "먼저 TV(Cast 기기)에 연결하세요."
            return false
        }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)

        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = live ? .live : .buffered
        builder.contentType = "application/x-mpegurl"
        builder.metadata = metadata
        switch format {
        case .fmp4:
            builder.hlsSegmentFormat = .FMP4
            builder.hlsVideoSegmentFormat = .FMP4
        case .ts:
            builder.hlsSegmentFormat = .TS
            builder.hlsVideoSegmentFormat = .MPEG2_TS
        }

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        let pending = client.loadMedia(with: request.build())
        pending.delegate = self
        loadRequest = pending
        // Anything else loaded replaces the mirror on the TV; castMirror sets this again.
        loadedMirrorURL = nil
        tvPlayback = .loading
        lastError = nil
        addEvent("재생 요청: \(title)")
        return true
    }

    /// Sends the iPhone screen stream to the TV. Without `force`, does nothing when this URL and
    /// revision were already sent in the current session (a new URL or revision, e.g. after a
    /// Wi-Fi change or outage, is always sent).
    @discardableResult
    func castMirror(_ url: URL, revision: Int, force: Bool) -> Bool {
        guard isConnected else { return false }
        if !force, loadedMirrorURL == url, loadedMirrorRevision == revision { return false }
        let sentAt = HostClock.now()
        guard load(url: url, title: "내 iPhone 화면", live: true, format: .fmp4) else { return false }
        startupPlayback = PlaybackTrace(origin: sentAt)
        loadedMirrorURL = url
        loadedMirrorRevision = revision
        if let token = Self.token(of: url) { mirrorTokens.insert(token) }
        return true
    }

    /// Stops the TV when it is playing our mirror stream (the broadcast ended), leaving other media alone.
    func stopMirror() {
        guard loadedMirrorURL != nil else { return }
        loadedMirrorURL = nil
        stopMedia()
    }

    func stopMedia() {
        remoteClient?.stop()
        addEvent("TV 재생 중지 요청")
    }

    /// First path component of a stream URL (`/<token>/live.m3u8`), the per-broadcast secret.
    static func token(of url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 ? parts[0] : nil
    }

    @objc private func castStateDidChange(_ notification: Notification) {
        refreshState()
    }

    private func refreshState() {
        #if MD_DEMO
        // Store screenshots: keep the fake TV (the simulator finds no real one).
        if isDemo { return }
        #endif
        let context = GCKCastContext.sharedInstance()
        switch context.castState {
        case .noDevicesAvailable: stateText = "기기를 찾지 못함"; connection = .noDevices
        case .notConnected: stateText = "연결 안 됨"; connection = .notConnected
        case .connecting: stateText = "연결 중…"; connection = .connecting
        case .connected: stateText = "연결됨"; connection = .connected
        @unknown default: stateText = "알 수 없음"; connection = .notConnected
        }
        if connection == .noDevices {
            if noDevicesSince == nil { noDevicesSince = Date() }
        } else {
            noDevicesSince = nil
        }
        isConnected = connection == .connected
        if !isConnected {
            // The next connection (new, resumed or reconnected session) gets the mirror again.
            loadedMirrorURL = nil
            tvPlayback = .none
        }
        let session = context.sessionManager.currentCastSession
        deviceName = session?.device.friendlyName
        if isConnected, let session {
            tvVolume = session.currentDeviceVolume
            tvMuted = session.currentDeviceMuted
        } else {
            tvVolume = nil
            tvMuted = false
        }
        // Attach to the session's media client here (cast-state changes cover start and resume).
        if let client = session?.remoteMediaClient, client !== observedClient {
            observedClient?.remove(self)
            client.add(self)
            observedClient = client
        }
    }

    /// "라이브 끝에서 X.X초 뒤" for diagnostics, with the raw values it came from.
    var liveLagText: String {
        guard let liveLag else { return "알 수 없음" }
        return String(format: "라이브 끝에서 %.1f초 뒤 (끝 %.1f, 위치 %.1f)",
                      liveLag.end - liveLag.position, liveLag.end, liveLag.position)
    }

    /// End of the receiver's live seekable range and its (extrapolated) playback position.
    /// End minus position is buffering behind the newest segment the receiver knows about;
    /// encoding and playlist-polling time on top of that are not included. Not clamped at zero,
    /// so a negative value (receiver's range end held back) stays visible.
    private func refreshLiveLag() {
        var sample: (end: Double, position: Double)?
        if isConnected, let client = remoteClient, client.mediaStatus?.playerState == .playing {
            // Both return 0 with no media; the range end is invalid (not finite) when the stream is not live.
            let end = client.approximateLiveSeekableRangeEnd()
            let position = client.approximateStreamPosition()
            if end.isFinite, end > 0, position.isFinite, position > 0 {
                sample = (end, position)
            }
        }
        recordStartupLag(sample.map { $0.end - $0.position })
        // Publish only visible changes (one decimal) to avoid needless view updates.
        switch (sample, liveLag) {
        case (nil, nil):
            break
        case let (new?, old?) where abs(new.end - old.end) < 0.05 && abs(new.position - old.position) < 0.05:
            break
        default:
            liveLag = sample
        }
    }

    /// Once a second (lag timer) for the first 30 s after a mirror load; nil while not playing.
    private func recordStartupLag(_ lag: Double?) {
        guard var trace = startupPlayback else { return }
        let now = HostClock.now()
        guard trace.isRecording(at: now) else { return }
        trace.recordLag(lag, now: now)
        startupPlayback = trace
    }

    private func recordStartupState(_ status: GCKMediaStatus) {
        guard var trace = startupPlayback else { return }
        let now = HostClock.now()
        guard trace.isRecording(at: now) else { return }
        let phase: PlaybackTrace.Phase
        switch status.playerState {
        case .idle: phase = .idle
        case .loading: phase = .loading
        case .buffering: phase = .buffering
        case .playing: phase = .playing
        case .paused: phase = .paused
        default: phase = .unknown
        }
        var reason: String?
        if status.playerState == .idle {
            switch status.idleReason {
            case .finished: reason = "FINISHED"
            case .cancelled: reason = "CANCELLED"
            case .interrupted: reason = "INTERRUPTED"
            case .error: reason = "ERROR"
            default: reason = nil
            }
        }
        trace.recordState(phase, idleReason: reason, session: status.mediaSessionID, now: now)
        if trace != startupPlayback { startupPlayback = trace }
    }

    /// For other app parts (MirrorCastCoordinator) to note things in the "Cast 기록" list. No tokens.
    func logEvent(_ text: String) {
        addEvent(text)
    }

    private func addEvent(_ text: String) {
        events.append(Self.stamp() + " " + text)
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }

    private func describe(_ status: GCKMediaStatus) -> String {
        let state: String
        switch status.playerState {
        case .idle: state = "대기(idle)"
        case .playing: state = "재생 중"
        case .paused: state = "일시정지"
        case .buffering: state = "버퍼링"
        case .loading: state = "불러오는 중"
        default: state = "알 수 없음"
        }
        guard status.playerState == .idle else { return state }
        let reason: String
        switch status.idleReason {
        case .finished: reason = "끝남"
        case .cancelled: reason = "취소됨"
        case .interrupted: reason = "중단됨"
        case .error: reason = "오류"
        default: reason = "없음"
        }
        return "\(state), 이유: \(reason)"
    }

    private func playback(of status: GCKMediaStatus) -> TVPlayback {
        switch status.playerState {
        case .playing: return .playing
        case .paused: return .paused
        case .buffering, .loading: return .loading
        case .idle:
            switch status.idleReason {
            case .error: return .failed
            case .finished, .cancelled, .interrupted: return .ended
            // Idle with no reason: nothing loaded yet, or a load just sent and not started.
            default: return tvPlayback == .loading ? .loading : .none
            }
        default: return tvPlayback
        }
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

extension CastManager: GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        addEvent("연결됨: \(session.device.friendlyName ?? "?")")
        refreshState()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        addEvent("연결 끊김" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        refreshState()
    }

    /// The TV's volume or mute changed (from this app, the TV remote, or another sender).
    func sessionManager(_ sessionManager: GCKSessionManager, session: GCKSession,
                        didReceiveDeviceVolume volume: Float, muted: Bool) {
        tvVolume = volume
        tvMuted = muted
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        lastError = "연결 실패: \(error.localizedDescription)"
        addEvent(lastError ?? "")
        refreshState()
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else { mediaText = "-"; tvPlayback = .none; return }
        recordStartupState(mediaStatus)
        let text = describe(mediaStatus)
        if text != mediaText { addEvent("TV 상태: \(text)") }
        mediaText = text
        tvPlayback = playback(of: mediaStatus)
        if mediaStatus.playerState == .idle, mediaStatus.idleReason == .error {
            lastError = "TV가 재생에 실패했어요 (idleReason=error). 진단 화면의 요청 기록을 확인하세요."
        }
    }
}

extension CastManager: GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        if request === loadRequest { loadRequest = nil }
        addEvent("요청 완료 (#\(request.requestID))")
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        if request === loadRequest {
            loadRequest = nil
            tvPlayback = .failed
        }
        lastError = "요청 실패: \(error.localizedDescription) (code \(error.code))"
        addEvent(lastError ?? "")
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        if request === loadRequest { loadRequest = nil }
        addEvent("요청 중단 (reason \(abortReason.rawValue))")
    }
}

extension CastManager: GCKLoggerDelegate {
    func logMessage(_ message: String, at level: GCKLoggerLevel, fromFunction function: String, location: String) {
        let line = "\(Self.stamp()) [\(level.rawValue)] \(function) \(message)"
        DispatchQueue.main.async {
            self.sdkLog.append(line)
            if self.sdkLog.count > 300 { self.sdkLog.removeFirst(self.sdkLog.count - 300) }
        }
    }
}
