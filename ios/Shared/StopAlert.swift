import Foundation

/// "TV 보내기가 멈췄어요" local notification. iOS ends the broadcast when the iPhone locks and the
/// extension may get no callback, so while broadcasting the extension keeps ONE pending notification
/// a few seconds in the future and pushes it out again from its tick (a dead-man switch): if the
/// extension is killed or suspended, the notification fires. A normal stop removes it.
/// Extension side: MirrorDropBroadcast/StopAlertArmer.swift. App side: App/StopAlertCenter.swift.
enum StopAlert {
    /// Fixed identifier: adding a request with the same identifier replaces the pending one.
    static let identifier = "mirrordrop.broadcast-stopped"
    /// Localized from the bundle of the process that schedules it: the broadcast extension, whose
    /// own String Catalog (MirrorDropBroadcast/Localizable.xcstrings) has the English text.
    static var title: String { String(localized: "TV 보내기가 멈췄어요") }
    static var body: String { String(localized: "iPhone이 잠기면 TV 보내기가 끝나요. 눌러서 다시 시작하세요.") }
    /// The notification fires this long after the extension last re-armed it.
    static let fireDelay: TimeInterval = 6
    /// How often the extension re-arms it (the pipeline ticks every 0.1 s; re-adding that often is waste).
    static let rearmInterval: TimeInterval = 2
    /// While notifications are not allowed, how often the extension asks again (the app asks for
    /// permission when a broadcast first starts, so it can be granted mid-broadcast).
    static let settingsRecheckInterval: TimeInterval = 10
}

/// Decides when the extension re-arms the notification. Pure logic, tested in StopAlertTests.
struct StopAlertSchedule {
    enum Action: Equatable {
        case none
        /// Add the request again (replaces the pending one).
        case arm
        /// Re-arming came late, so the previous request has probably fired already although the
        /// broadcast is alive: also remove the delivered notification, then add the request again.
        case armAfterMiss
    }

    /// Wall-clock seconds of the last re-arm (the trigger counts wall time, so this does too).
    private(set) var lastArmed: Double?

    mutating func next(now: Double) -> Action {
        guard let lastArmed else {
            self.lastArmed = now
            return .arm
        }
        let elapsed = now - lastArmed
        // A clock set backwards re-arms at once.
        guard elapsed >= StopAlert.rearmInterval || elapsed < 0 else { return .none }
        self.lastArmed = now
        return elapsed >= StopAlert.fireDelay ? .armAfterMiss : .arm
    }

    /// Broadcast ended normally (the request is removed); the next start arms at once.
    mutating func reset() {
        lastArmed = nil
    }
}
