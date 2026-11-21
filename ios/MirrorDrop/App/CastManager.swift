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

    @Published private(set) var stateText = String(localized: "준비 중")
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
    /// TV side of "시작 기록" (the FIRST mirror load of the current broadcast) and "다시 보내기 기록"
    /// (the latest re-load of it): player states and live lag for 30 s after each. Shared/StartupTrace.swift.
    @Published private(set) var playbackRecords = PlaybackRecords()
    var startupPlayback: PlaybackTrace? { playbackRecords.startup }
    var resendPlayback: PlaybackTrace? { playbackRecords.resend }
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
        stateText = String(localized: "연결됨")
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
            mediaText = String(localized: "재생 중")
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
        // Common run-loop modes: a timer in the default mode does not fire while the user scrolls
        // (e.g. the diagnostics list), which left holes in the live-lag record.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLiveLag()
        }
        RunLoop.main.add(timer, forMode: .common)
        lagTimer = timer
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
            lastError = String(localized: "먼저 TV(Cast 기기)에 연결하세요.")
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
        addEvent("load request: \(title)")
        return true
    }

    /// Sends the iPhone screen stream to the TV. Without `force`, does nothing when this URL and
    /// revision were already sent in the current session (a new URL or revision, e.g. after a
    /// Wi-Fi change or outage, is always sent). `reason` goes to the Cast events and the records.
    @discardableResult
    func castMirror(_ url: URL, revision: Int, force: Bool, reason: CastReason) -> Bool {
        guard isConnected else { return false }
        if !force, loadedMirrorURL == url, loadedMirrorRevision == revision { return false }
        // What the TV was doing just before: a re-load while it already played our stream restarts
        // the receiver's buffering. No URL or token in the log.
        let status = remoteClient?.mediaStatus
        let before = status.map(describeForLog) ?? "no media status"
        let sameStream = status?.mediaInformation?.contentURL == url
        addEvent("cast mirror (\(reason.rawValue), rev \(revision)\(force ? ", forced" : "")); "
                 + "TV before: \(before)\(sameStream ? ", same stream" : "")")
        let sentAt = HostClock.now()
        guard load(url: url, title: String(localized: "내 iPhone 화면"), live: true, format: .fmp4) else { return false }
        let token = Self.token(of: url)
        playbackRecords.loadSent(token: token, origin: sentAt, reason: reason)
        loadedMirrorURL = url
        loadedMirrorRevision = revision
        if let token { mirrorTokens.insert(token) }
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
        addEvent("stop request")
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
        case .noDevicesAvailable: stateText = String(localized: "기기를 찾지 못함"); connection = .noDevices
        case .notConnected: stateText = String(localized: "연결 안 됨"); connection = .notConnected
        case .connecting: stateText = String(localized: "연결 중…"); connection = .connecting
        case .connected: stateText = String(localized: "연결됨"); connection = .connected
        @unknown default: stateText = String(localized: "알 수 없음"); connection = .notConnected
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
        guard let liveLag else { return String(localized: "알 수 없음") }
        let behind = StartupReport.f1(liveLag.end - liveLag.position)
        let end = StartupReport.f1(liveLag.end)
        let position = StartupReport.f1(liveLag.position)
        return String(localized: "라이브 끝에서 \(behind)초 뒤 (끝 \(end), 위치 \(position))")
    }

    /// End of the receiver's live seekable range and its (extrapolated) playback position.
    /// End minus position is buffering behind the newest segment the receiver knows about;
    /// encoding and playlist-polling time on top of that are not included. Not clamped at zero,
    /// so a negative value (receiver's range end held back) stays visible.
    ///
    /// Runs from the 1 s timer and on every receiver status update while PLAYING (a short PLAYING
    /// stretch between bufferings is caught too; PlaybackTrace keeps samples at least 0.5 s apart).
    /// Build 16's records had no live-lag value at all. Samples are only taken while the app runs:
    /// once the play request is answered, a backgrounded app is suspended and takes none; and while
    /// the TV is not PLAYING (loading, buffering) a sample has no value. Each sample without a value
    /// now says why (PlaybackTrace.LagGap), and the summary shows the longest stretch with no sample.
    private func refreshLiveLag() {
        var sample: (end: Double, position: Double)?
        var gap: PlaybackTrace.LagGap?
        if !isConnected {
            gap = .notConnected
        } else if let client = remoteClient, client.mediaStatus?.playerState == .playing {
            // Both return 0 with no media; the range end is kGCKInvalidTimeInterval (not finite) when
            // the stream is not live or the receiver reported no seekable range.
            let end = client.approximateLiveSeekableRangeEnd()
            let position = client.approximateStreamPosition()
            if !(end.isFinite && end > 0) {
                gap = .noLiveRange
            } else if !(position.isFinite && position > 0) {
                gap = .noPosition
            } else {
                sample = (end, position)
            }
        } else {
            gap = .notPlaying
        }
        recordStartupLag(sample.map { $0.end - $0.position }, gap: gap)
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

    /// About once a second for the first 30 s after a mirror load (startup and resend records).
    private func recordStartupLag(_ lag: Double?, gap: PlaybackTrace.LagGap?) {
        let now = HostClock.now()
        guard playbackRecords.isRecording(at: now) else { return }
        var records = playbackRecords
        records.recordLag(lag, gap: gap, now: now)
        // Publish only real changes (closely spaced samples are dropped).
        if records != playbackRecords { playbackRecords = records }
    }

    private func recordStartupState(_ status: GCKMediaStatus) {
        let now = HostClock.now()
        guard playbackRecords.isRecording(at: now) else { return }
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
        var records = playbackRecords
        records.recordState(phase, idleReason: reason, session: status.mediaSessionID, now: now)
        if records != playbackRecords { playbackRecords = records }
    }

    /// For other app parts (MirrorCastCoordinator) to note things in the "Cast 기록" list. No tokens.
    /// Like the extension's log, these lines are English in every language.
    func logEvent(_ text: String) {
        addEvent(text)
    }

    private func addEvent(_ text: String) {
        events.append(Self.stamp() + " " + text)
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }

    /// Receiver state for the screen (고급·진단 "상태"), localized.
    private func describe(_ status: GCKMediaStatus) -> String {
        let state: String
        switch status.playerState {
        case .idle: state = String(localized: "대기(idle)")
        case .playing: state = String(localized: "재생 중")
        case .paused: state = String(localized: "일시정지")
        case .buffering: state = String(localized: "버퍼링")
        case .loading: state = String(localized: "불러오는 중")
        default: state = String(localized: "알 수 없음")
        }
        guard status.playerState == .idle else { return state }
        let reason: String
        switch status.idleReason {
        case .finished: reason = String(localized: "끝남")
        case .cancelled: reason = String(localized: "취소됨")
        case .interrupted: reason = String(localized: "중단됨")
        case .error: reason = String(localized: "오류")
        default: reason = String(localized: "없음")
        }
        return String(localized: "\(state), 이유: \(reason)")
    }

    /// Receiver state for the Cast events (English, like the other log lines), e.g. "IDLE/ERROR #3"
    /// (# = receiver media session).
    private func describeForLog(_ status: GCKMediaStatus) -> String {
        var text: String
        switch status.playerState {
        case .idle: text = "IDLE"
        case .playing: text = "PLAYING"
        case .paused: text = "PAUSED"
        case .buffering: text = "BUFFERING"
        case .loading: text = "LOADING"
        default: text = "UNKNOWN"
        }
        if status.playerState == .idle {
            switch status.idleReason {
            case .finished: text += "/FINISHED"
            case .cancelled: text += "/CANCELLED"
            case .interrupted: text += "/INTERRUPTED"
            case .error: text += "/ERROR"
            default: break
            }
        }
        return text + " #\(status.mediaSessionID)"
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
        addEvent("session started: \(session.device.friendlyName ?? "?")")
        refreshState()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        addEvent("session ended" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        refreshState()
    }

    /// The TV's volume or mute changed (from this app, the TV remote, or another sender).
    func sessionManager(_ sessionManager: GCKSessionManager, session: GCKSession,
                        didReceiveDeviceVolume volume: Float, muted: Bool) {
        tvVolume = volume
        tvMuted = muted
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        lastError = String(localized: "연결 실패: \(error.localizedDescription)")
        addEvent("session failed to start: \(error.localizedDescription)")
        refreshState()
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else { mediaText = "-"; tvPlayback = .none; return }
        recordStartupState(mediaStatus)
        let text = describe(mediaStatus)
        if text != mediaText { addEvent("TV state: \(describeForLog(mediaStatus))") }
        mediaText = text
        tvPlayback = playback(of: mediaStatus)
        if mediaStatus.playerState == .idle, mediaStatus.idleReason == .error {
            lastError = String(localized: "TV가 재생에 실패했어요 (idleReason=error). 진단 화면의 요청 기록을 확인하세요.")
        }
        // A PLAYING stretch between bufferings can be shorter than the 1 s timer.
        if mediaStatus.playerState == .playing { refreshLiveLag() }
    }
}

extension CastManager: GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        if request === loadRequest { loadRequest = nil }
        addEvent("request done (#\(request.requestID))")
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        if request === loadRequest {
            loadRequest = nil
            tvPlayback = .failed
        }
        lastError = String(localized: "요청 실패: \(error.localizedDescription) (code \(error.code))")
        addEvent("request failed: \(error.localizedDescription) (code \(error.code))")
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        if request === loadRequest { loadRequest = nil }
        addEvent("request aborted (reason \(abortReason.rawValue))")
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
