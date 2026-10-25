import Foundation
import GoogleCast

/// Wraps the Google Cast sender SDK: discovery/session state, loading media, receiver status and SDK logs.
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()
    /// Default Media Receiver. Must match the _CC1AD845._googlecast._tcp entry in NSBonjourServices.
    static let receiverAppID = "CC1AD845"

    enum SegmentFormat { case fmp4, ts }

    @Published private(set) var stateText = "준비 중"
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName: String?
    @Published private(set) var mediaText = "-"
    @Published private(set) var lastError: String?
    @Published private(set) var events: [String] = []
    private(set) var sdkLog: [String] = []
    private var isSetUp = false
    private weak var observedClient: GCKRemoteMediaClient?

    func setUp() {
        guard !isSetUp else { return }
        isSetUp = true
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: Self.receiverAppID))
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKLogger.sharedInstance().delegate = self

        let context = GCKCastContext.sharedInstance()
        context.sessionManager.add(self)
        NotificationCenter.default.addObserver(self, selector: #selector(castStateDidChange),
                                               name: NSNotification.Name.gckCastStateDidChange, object: context)
        refreshState()
    }

    private var remoteClient: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
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
        lastError = nil
        addEvent("재생 요청: \(title)")
        return true
    }

    func stopMedia() {
        remoteClient?.stop()
        addEvent("TV 재생 중지 요청")
    }

    @objc private func castStateDidChange(_ notification: Notification) {
        refreshState()
    }

    private func refreshState() {
        let context = GCKCastContext.sharedInstance()
        switch context.castState {
        case .noDevicesAvailable: stateText = "기기를 찾지 못함"
        case .notConnected: stateText = "연결 안 됨"
        case .connecting: stateText = "연결 중…"
        case .connected: stateText = "연결됨"
        @unknown default: stateText = "알 수 없음"
        }
        isConnected = context.castState == .connected
        let session = context.sessionManager.currentCastSession
        deviceName = session?.device.friendlyName
        // Attach to the session's media client here (cast-state changes cover start and resume).
        if let client = session?.remoteMediaClient, client !== observedClient {
            observedClient?.remove(self)
            client.add(self)
            observedClient = client
        }
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

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        lastError = "연결 실패: \(error.localizedDescription)"
        addEvent(lastError ?? "")
        refreshState()
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else { mediaText = "-"; return }
        let text = describe(mediaStatus)
        if text != mediaText { addEvent("TV 상태: \(text)") }
        mediaText = text
        if mediaStatus.playerState == .idle, mediaStatus.idleReason == .error {
            lastError = "TV가 재생에 실패했어요 (idleReason=error). 진단 화면의 요청 기록을 확인하세요."
        }
    }
}

extension CastManager: GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        addEvent("요청 완료 (#\(request.requestID))")
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        lastError = "요청 실패: \(error.localizedDescription) (code \(error.code))"
        addEvent(lastError ?? "")
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
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
