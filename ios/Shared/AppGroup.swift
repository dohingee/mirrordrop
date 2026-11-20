import Foundation

/// Shared between the app and the broadcast extension through the App Group.
enum AppGroup {
    static let id = "group.com.mirrordrop.app"
    static let broadcastExtensionID = "com.mirrordrop.app.broadcast"
    static let statusKey = "broadcastStatus"
    static let includeAudioKey = "includeAppAudio"
    /// `LatencyPreset.rawValue`, read by the extension at broadcast start.
    static let latencyPresetKey = "latencyPreset"
    /// Darwin notification posted by the extension whenever it writes a new status.
    static let statusNotification = "com.mirrordrop.app.status-changed"

    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
}

enum BroadcastState: String, Codable {
    case idle, starting, streaming, stopped, failed
}

struct RequestLogEntry: Codable, Equatable, Identifiable {
    var id: Int
    var time: Date
    var client: String
    var method: String
    var path: String
    var status: Int
    var bytes: Int
}

/// Snapshot of the extension's state, written by the extension and read by the app.
struct BroadcastStatus: Codable, Equatable {
    var state: BroadcastState = .idle
    /// Stream URL. Nil until the server is ready, and again while there is no Wi-Fi address
    /// (see `networkIssue`). It changes when the Wi-Fi IP or the listener port changes.
    var url: String?
    /// Rises by one every time a usable `url` is published, including when the same URL comes back
    /// after a Wi-Fi outage, so the app can re-send it to the TV even if the text is unchanged.
    var urlRevision = 0
    /// Why the stream is unreachable right now (for example no Wi-Fi), or nil when it is reachable.
    var networkIssue: String?
    var startedAt: Date?
    var updatedAt = Date()
    var memoryMB: Double = 0
    var peakMemoryMB: Double = 0
    var framesIn = 0
    var framesEncoded = 0
    var framesRepeated = 0
    var framesSkipped = 0
    var framesDropped = 0
    var audioEnabled = false
    /// `LatencyPreset.code` the extension actually used for this broadcast.
    var latencyPreset: String?
    var audioSamplesIn = 0
    var segmentsProduced = 0
    var segmentsInWindow = 0
    var lastSegmentDuration: Double = 0
    var lastSegmentBytes = 0
    var codecs: String?
    var orientation: UInt32 = 1
    var requestCount = 0
    var clients: [String: Int] = [:]
    var recentRequests: [RequestLogEntry] = []
    var errors: [String] = []
    var log: [String] = []
}

enum StatusStore {
    static func write(_ status: BroadcastStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        AppGroup.defaults?.set(data, forKey: AppGroup.statusKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppGroup.statusNotification as CFString),
            nil, nil, true)
    }

    static func read() -> BroadcastStatus? {
        guard let data = AppGroup.defaults?.data(forKey: AppGroup.statusKey) else { return nil }
        return try? JSONDecoder().decode(BroadcastStatus.self, from: data)
    }
}
