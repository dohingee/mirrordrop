import Foundation

/// The LAN address the stream is published on: Wi-Fi IPv4 + listener port + per-broadcast token.
/// Either part can change during a broadcast (Wi-Fi switched or lost, listener restarted), and the
/// app re-sends the new URL to the TV when `BroadcastStatus.url` / `urlRevision` change.
struct StreamAddress: Equatable {
    let token: String
    private(set) var ip: String?
    private(set) var port: UInt16?

    init(token: String, ip: String? = nil, port: UInt16? = nil) {
        self.token = token
        self.ip = ip
        self.port = port
    }

    /// Nil while there is no Wi-Fi address or the listener is not ready.
    var url: String? {
        guard let ip, !ip.isEmpty, let port, port != 0 else { return nil }
        return Self.url(ip: ip, port: port, token: token)
    }

    static func url(ip: String, port: UInt16, token: String) -> String {
        "http://\(ip):\(port)/\(token)/\(HLSPlaylist.masterName)"
    }

    /// Returns true when the address changed.
    @discardableResult
    mutating func update(ip newIP: String?) -> Bool {
        guard newIP != ip else { return false }
        ip = newIP
        return true
    }

    /// Returns true when the port changed. Port 0 means "unknown" and is ignored.
    @discardableResult
    mutating func update(port newPort: UInt16) -> Bool {
        guard newPort != 0, newPort != port else { return false }
        port = newPort
        return true
    }
}

/// Decides when a published stream URL gets a new `BroadcastStatus.urlRevision` (the app sends a
/// new revision to the TV again, which restarts its buffering). Only when the URL text changed, or
/// when the stream was unreachable (no URL: no Wi-Fi address, listener not ready) for at least
/// `outageThreshold` s, so the TV's connection probably failed. A short blip (a path update or an
/// empty IP read while the screen locks, build 16) brings the same URL back with the same revision.
/// Pure logic, tested in StabilityTests.
struct StreamURLRevision: Equatable {
    static let outageThreshold: Double = 3

    private(set) var revision = 0
    /// Last URL that got a revision.
    private(set) var lastURL: String?
    /// Clock seconds since when no URL has been published (nil while there is one).
    private(set) var unreachableSince: Double?

    /// Feeds the current URL (nil: unreachable). Returns true when the revision rose.
    @discardableResult
    mutating func update(url: String?, now: Double) -> Bool {
        guard let url else {
            if unreachableSince == nil { unreachableSince = now }
            return false
        }
        let longOutage = unreachableSince.map { now - $0 >= Self.outageThreshold } ?? false
        unreachableSince = nil
        guard url != lastURL || longOutage else { return false }
        lastURL = url
        revision += 1
        return true
    }
}
