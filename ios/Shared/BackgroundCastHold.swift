import Foundation

/// The app (not the extension) sends the "play" request to the TV, and only once the extension has
/// enough segments (a few seconds after the broadcast starts). If the user leaves the app before
/// that, iOS suspends it within seconds and the request is never sent. So while that request is
/// still to come, the app holds a finite-length background task (`beginBackgroundTask`), never a
/// background mode (docs/SPEC.md 8). App side: App/MirrorCastCoordinator.swift.
/// Pure logic, tested in BackgroundCastHoldTests.
enum BackgroundCastHold {
    /// Cast connection in the terms that matter here.
    enum Link: Equatable { case none, connecting, connected }

    struct Input: Equatable {
        /// The app is in the background (it keeps running only while it holds a background task).
        var inBackground: Bool
        /// The extension is starting or streaming (and not stale).
        var broadcastLive: Bool
        var link: Link
        /// The extension has published a stream that is ready for the TV.
        var streamReady: Bool
        /// The app already handled the current ready stream for the current connection
        /// (sent the play request, or found it was already sent).
        var autoCastDone: Bool
        /// A play request was sent and the TV has not answered yet.
        var loadInFlight: Bool
    }

    /// Why the app does not (or no longer) need to stay awake. Raw values go to the Cast event log.
    enum Release: String, Equatable {
        case foreground = "app in front"
        case notLive = "broadcast not running"
        case noTV = "no TV connected"
        case delivered = "play request sent"
    }

    /// nil: hold (or start) the background task; otherwise the reason to end it.
    static func release(for input: Input) -> Release? {
        guard input.inBackground else { return .foreground }
        guard input.broadcastLive else { return .notLive }
        // Connecting counts: the session can come back (resume/reconnect) and then gets the stream.
        guard input.link != .none else { return .noTV }
        if input.streamReady, input.autoCastDone, !input.loadInFlight { return .delivered }
        return nil
    }
}

/// Decides when the app sends the mirror to the TV by itself: whenever the ready stream URL, its
/// `urlRevision` or the connection changes (a new broadcast, a new address after a Wi-Fi change,
/// or a reconnect). Nothing is sent again while these stay the same, so another video the user
/// played from "고급·진단" is not replaced. Pure logic, tested in BackgroundCastHoldTests.
struct AutoCastTrigger: Equatable {
    struct Key: Equatable {
        var url: String?
        var revision: Int
        var connected: Bool
    }

    private(set) var lastKey: Key?

    /// True when the app should ask the TV to play `url` now.
    mutating func shouldCast(url: String?, revision: Int, connected: Bool) -> Bool {
        castReason(url: url, revision: revision, connected: connected) != nil
    }

    /// Why the app should ask the TV to play `url` now, or nil when it should not (the same rule as
    /// `shouldCast`). The reason goes to the Cast events and the startup / resend records, so a
    /// report tells why a reload happened.
    mutating func castReason(url: String?, revision: Int, connected: Bool) -> CastReason? {
        let key = Key(url: url, revision: revision, connected: connected)
        guard key != lastKey else { return nil }
        let previous = lastKey
        lastKey = key
        guard url != nil, connected else { return nil }
        guard let previous, previous.url != nil else { return .autoStreamReady }
        if !previous.connected { return .autoConnected }
        if previous.url != url { return .autoNewAddress }
        return .autoNewRevision
    }

    /// The current ready stream was already handled for this connection.
    func isDone(url: String?, revision: Int, connected: Bool) -> Bool {
        url != nil && connected && lastKey == Key(url: url, revision: revision, connected: connected)
    }
}

/// Why a play request for the mirror was sent (CastManager.castMirror). Raw values are English
/// for the Cast events (logs stay English); `label` is the localized text of the diagnostics records.
enum CastReason: String, Equatable {
    /// The stream became ready while a TV was connected (normally the first send of a broadcast).
    case autoStreamReady = "auto: stream ready"
    /// A TV connected, or the session came back (new, resumed or reconnected) with the stream ready.
    case autoConnected = "auto: TV connected or reconnected"
    /// The stream URL changed (new Wi-Fi address or port).
    case autoNewAddress = "auto: new stream address"
    /// Same URL with a new `urlRevision` (it came back after a Wi-Fi outage).
    case autoNewRevision = "auto: new urlRevision"
    /// "다시 TV에 띄우기" on the main screen.
    case manualMain = "manual: main screen"
    /// "지금 TV에 띄우기" in 고급·진단.
    case manualAdvanced = "manual: advanced screen"

    var label: String {
        switch self {
        case .autoStreamReady: return String(localized: "자동: 화면이 준비됨")
        case .autoConnected: return String(localized: "자동: TV 연결(다시 연결)됨")
        case .autoNewAddress: return String(localized: "자동: 스트림 주소가 바뀜")
        case .autoNewRevision: return String(localized: "자동: 같은 주소로 다시 열림(urlRevision)")
        case .manualMain: return String(localized: "직접: 첫 화면 \"다시 TV에 띄우기\"")
        case .manualAdvanced: return String(localized: "직접: 고급·진단 \"지금 TV에 띄우기\"")
        }
    }
}

/// Whether an automatic play request can be skipped because the TV already plays this very stream.
/// Every re-load restarts the receiver's buffering (build 16: a re-load after the screen went off and
/// on was followed by 9 bufferings, 19.9 s in 30 s). App side: CastManager.castMirror.
/// Pure logic, tested in BackgroundCastHoldTests.
enum MirrorReloadPolicy {
    /// What the app knows about the receiver right before an automatic send.
    enum TVStatus: Equatable {
        /// The session has no media status yet (just connected or resumed); worth waiting for.
        case unknown
        /// The receiver's media status: its content URL (nil when none) and player state.
        case known(contentURL: String?, phase: PlaybackTrace.Phase)
    }

    enum Decision: Equatable {
        /// Send the play request.
        case load
        /// The TV already plays (or loads) this stream: record it as delivered, no request.
        case skip
        /// No media status yet: ask the receiver for one and decide when it comes (or after
        /// `statusWait` s, then `load`).
        case waitForStatus
    }

    /// How long an automatic send waits for the first media status of a new or resumed session.
    static let statusWait: Double = 2

    /// `force`: the user pressed a button, always re-load. `mayWait`: false once the wait is over.
    static func decide(url: String, force: Bool, tv: TVStatus, mayWait: Bool) -> Decision {
        guard !force else { return .load }
        switch tv {
        case .unknown:
            return mayWait ? .waitForStatus : .load
        case let .known(contentURL, phase):
            guard contentURL == url else { return .load }
            switch phase {
            case .playing, .buffering, .paused, .loading: return .skip
            case .idle, .unknown: return .load
            }
        }
    }
}

/// Clearing the TV after the broadcast ended. Build 17 sent one stop request when the app noticed the
/// end; the app had been suspended, the Cast socket had died meanwhile (GCKNSSLSocket -9805/-9806), so
/// the request went nowhere and the TV kept buffering the dead stream for a minute. Now the end leaves
/// a "clear the TV" intent, and the app (re)sends the stop whenever the receiver's media status shows
/// one of OUR mirror streams while no broadcast is live: right away when the session is fine, after it
/// resumed or reconnected otherwise, and when the app comes back to the front. Other media is never
/// stopped. App side: CastManager.updateMirrorClear. Pure logic, tested in BackgroundCastHoldTests.
enum MirrorStopPolicy {
    /// The receiver's media in the terms that matter here.
    enum TVStatus: Equatable {
        /// No media status (yet): a new or resumed session, or none received since launch.
        case unknown
        /// Our mirror stream (its token is one we sent or the extension's last one) in this state.
        case ours(PlaybackTrace.Phase)
        /// No media, or media that is not ours.
        case notOurs
    }

    enum Decision: Equatable {
        case none
        /// Send a stop request to the receiver.
        case stop
        /// The status is unknown while a clear is pending: ask the receiver for its status.
        case askStatus
        /// The TV no longer shows our stream: the pending clear is done.
        case cleared
        /// A broadcast is live again (it gets the new stream): drop the pending clear.
        case cancel
    }

    /// At least this long between two requests (stop or status) for the same stream, unless the session
    /// came back in between (then the throttle is reset): status updates while the TV still buffers
    /// would send a stop each.
    static let resendInterval: Double = 5

    /// `pending`: a broadcast ended and the TV has not been seen cleared yet. `connected`: the Cast
    /// session is connected (the socket may still turn out dead; the throttle and the next status
    /// cover that). `secondsSinceLastRequest`: since the last stop or status request, nil when none
    /// was sent since the session (re)started.
    static func decide(broadcastLive: Bool, pending: Bool, connected: Bool, tv: TVStatus,
                       secondsSinceLastRequest: Double?) -> Decision {
        if broadcastLive { return pending ? .cancel : .none }
        let throttled = secondsSinceLastRequest.map { $0 >= 0 && $0 < resendInterval } ?? false
        switch tv {
        case let .ours(phase):
            // IDLE: the receiver stopped (by our request, the TV remote, or an error); nothing spins.
            if phase == .idle { return pending ? .cleared : .none }
            guard connected, !throttled else { return .none }
            return .stop
        case .notOurs:
            return pending ? .cleared : .none
        case .unknown:
            guard pending, connected, !throttled else { return .none }
            return .askStatus
        }
    }

    /// Whether the receiver's content (its content URL, or the content ID it was loaded under) is one of
    /// our mirror streams: `http://<ip>:<port>/<token>/live.m3u8` with a known token.
    static func isMirror(_ content: String?, tokens: Set<String>) -> Bool {
        guard let token = token(of: content) else { return false }
        return tokens.contains(token)
    }

    /// First path component of a stream URL (`/<token>/live.m3u8`), the per-broadcast secret.
    static func token(of content: String?) -> String? {
        guard let content, let url = URL(string: content) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 ? parts[0] : nil
    }
}
