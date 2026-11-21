import Foundation

/// Shared between the app and the broadcast extension through the App Group.
enum AppGroup {
    static let id = "group.com.mirrordrop.app"
    static let broadcastExtensionID = "com.mirrordrop.app.broadcast"
    static let statusKey = "broadcastStatus"
    /// `AudioOutput.rawValue`, read by the extension during a broadcast (can change live).
    static let audioOutputKey = "audioOutput"
    /// Darwin notification posted by the app when the audio output changes.
    static let audioOutputNotification = "com.mirrordrop.app.audio-output-changed"
    /// Keys of earlier builds that nothing reads any more ("includeAppAudio": the old
    /// "앱 소리 포함 (실험)" switch, replaced by `audioOutputKey`).
    static let legacyKeys = ["includeAppAudio"]
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
    /// `LatencyPreset.code` the extension actually used for this broadcast.
    var latencyPreset: String?
    /// `AudioOutput.code` in use right now ("tv": real sound to the TV, "phone": silence to the TV).
    var audioOutput: String?
    /// Real app-sound buffers received from ReplayKit.
    var audioSamplesIn = 0
    /// Format of the last real app-sound buffer, e.g. "44100Hz 2ch s16be".
    var audioSourceFormat: String?
    /// Silent frames (48 kHz) written to keep the audio track going (no sound, or "phone" output).
    var audioSilentFrames = 0
    /// Real frames written to the TV stream (muted ones included).
    var audioRealFrames = 0
    /// Real frames left out (arrived too late, encoder busy, or format not readable).
    var audioDroppedFrames = 0
    /// Loudest real sample in about the last second, 0...1 (measured before muting, so a device
    /// test can see whether sound still arrives with the phone volume at 0).
    var audioPeakRecent: Double = 0
    /// Loudest real sample since the broadcast started, 0...1.
    var audioPeakMax: Double = 0
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
    /// "시작 기록": the first 30 s from the first video frame (fixed-size, no tokens).
    var startup = StartupTrace()
}

extension BroadcastStatus {
    /// Missing keys (a status written by an older build) keep their defaults instead of failing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init()
        state = value(.state, state)
        url = value(.url, url)
        urlRevision = value(.urlRevision, urlRevision)
        networkIssue = value(.networkIssue, networkIssue)
        startedAt = value(.startedAt, startedAt)
        updatedAt = value(.updatedAt, updatedAt)
        memoryMB = value(.memoryMB, memoryMB)
        peakMemoryMB = value(.peakMemoryMB, peakMemoryMB)
        framesIn = value(.framesIn, framesIn)
        framesEncoded = value(.framesEncoded, framesEncoded)
        framesRepeated = value(.framesRepeated, framesRepeated)
        framesSkipped = value(.framesSkipped, framesSkipped)
        framesDropped = value(.framesDropped, framesDropped)
        latencyPreset = value(.latencyPreset, latencyPreset)
        audioOutput = value(.audioOutput, audioOutput)
        audioSamplesIn = value(.audioSamplesIn, audioSamplesIn)
        audioSourceFormat = value(.audioSourceFormat, audioSourceFormat)
        audioSilentFrames = value(.audioSilentFrames, audioSilentFrames)
        audioRealFrames = value(.audioRealFrames, audioRealFrames)
        audioDroppedFrames = value(.audioDroppedFrames, audioDroppedFrames)
        audioPeakRecent = value(.audioPeakRecent, audioPeakRecent)
        audioPeakMax = value(.audioPeakMax, audioPeakMax)
        segmentsProduced = value(.segmentsProduced, segmentsProduced)
        segmentsInWindow = value(.segmentsInWindow, segmentsInWindow)
        lastSegmentDuration = value(.lastSegmentDuration, lastSegmentDuration)
        lastSegmentBytes = value(.lastSegmentBytes, lastSegmentBytes)
        codecs = value(.codecs, codecs)
        orientation = value(.orientation, orientation)
        requestCount = value(.requestCount, requestCount)
        clients = value(.clients, clients)
        recentRequests = value(.recentRequests, recentRequests)
        errors = value(.errors, errors)
        log = value(.log, log)
        startup = value(.startup, startup)
    }
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
