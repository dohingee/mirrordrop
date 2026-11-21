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
        let key = Key(url: url, revision: revision, connected: connected)
        guard key != lastKey else { return false }
        lastKey = key
        return url != nil && connected
    }

    /// The current ready stream was already handled for this connection.
    func isDone(url: String?, revision: Int, connected: Bool) -> Bool {
        url != nil && connected && lastKey == Key(url: url, revision: revision, connected: connected)
    }
}
