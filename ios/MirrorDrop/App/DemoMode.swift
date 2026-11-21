import Foundation

/// App Store screenshots without a TV: `-MDDemo connected|sending` shows the main screen as if a
/// Google Cast TV were connected (and, for `sending`, as if the screen were being sent).
///
/// Only the simulator launch check compiles this in (.github/scripts/ios-launch-check.sh builds with
/// the `MD_DEMO` compilation condition). The archive for TestFlight and the App Store is built without
/// it, so there `current` is always nil and no fake state code exists in the shipped app. Even in a
/// demo build nothing changes unless the launch argument is present (normal launches have none).
enum DemoMode: String {
    case connected, sending

    static let current: DemoMode? = {
        #if MD_DEMO
        return UserDefaults.standard.string(forKey: "MDDemo").flatMap(DemoMode.init(rawValue:))
        #else
        return nil
        #endif
    }()

    #if MD_DEMO
    static let tvName = "거실 TV"
    /// Looks like a real stream address; the token part is a fixed placeholder, nothing listens on it.
    static let streamURL = URL(string: "http://192.168.0.10:8765/demo/live.m3u8")!

    /// What the broadcast extension would report while sending (kept fresh by BroadcastMonitor).
    static func status(now: Date) -> BroadcastStatus {
        var status = BroadcastStatus()
        status.state = .streaming
        status.url = streamURL.absoluteString
        status.urlRevision = 1
        status.startedAt = now.addingTimeInterval(-60)
        status.updatedAt = now
        status.latencyPreset = LatencyPreset.default.code
        status.audioOutput = AudioOutput.tv.rawValue
        return status
    }
    #endif
}
