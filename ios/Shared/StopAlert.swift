import Foundation

/// "TV 보내기가 끝났어요" local notification. iOS ends the broadcast when the iPhone locks and the
/// extension may get no callback, so while broadcasting the extension keeps ONE pending notification
/// a few seconds in the future and pushes it out again from its tick (a dead-man switch): if the
/// extension is killed or suspended, the notification fires. When the broadcast finishes with a
/// callback, the alert fires in `finishFireDelay` s unless the user stopped it from MirrorDrop
/// (StopAlertFinish).
/// Extension side: MirrorDropBroadcast/StopAlertArmer.swift. App side: App/StopAlertCenter.swift.
enum StopAlert {
    /// Fixed identifier: adding a request with the same identifier replaces the pending one.
    static let identifier = "mirrordrop.broadcast-stopped"
    /// Localized from the bundle of the process that schedules it: the broadcast extension, whose
    /// own String Catalog (MirrorDropBroadcast/Localizable.xcstrings) has the English text.
    /// It fires for a lock and for a stop from the red indicator in another app, so it does not say why.
    static var title: String { String(localized: "TV 보내기가 끝났어요") }
    static var body: String { String(localized: "다시 보려면 눌러서 시작하세요.") }
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

// MARK: When the broadcast finishes

/// Build 17 tried to tell a lock from a user stop with a file under complete data protection, read
/// for 11 s after `broadcastFinished`. On the device (iOS 27) iOS ended the extension within about
/// a second of `broadcastFinished`, so the follow-up reads never ran and a lock gave no alert.
/// Build 18 rule: when the broadcast finishes, the extension schedules the alert AT ONCE (it fires in
/// `finishFireDelay` s), unless the user stopped it from inside MirrorDrop: the app writes the time of
/// a tap on the main screen's stop card to the App Group (`AppGroup.userStopRequestedKey`), and the
/// extension skips the alert when that is at most `userStopWindow` s old. A stop while MirrorDrop is
/// in front is covered by the app itself: it removes the pending and shown alert when it sees the
/// broadcast end while active (App/MirrorCastCoordinator.swift).
extension StopAlert {
    /// The alert fires this long after the broadcast finished (must be > 0 for the trigger). Short, so
    /// it is scheduled before iOS ends the extension, and the app in front can still take it back.
    static let finishFireDelay: TimeInterval = 2
    /// A tap on MirrorDrop's stop card at most this long before the finish counts as a user stop (the
    /// tap opens the system sheet; "Stop Broadcast" there comes a few seconds later).
    static let userStopWindow: TimeInterval = 30
}

/// What the extension does with the alert when the broadcast has finished. Pure logic, tested in
/// StopAlertTests.
enum StopAlertFinish {
    enum Action: Equatable {
        /// Schedule the alert in `StopAlert.finishFireDelay` s (lock, or a stop outside MirrorDrop).
        case fire
        /// The user stopped it from MirrorDrop's stop card: remove the alert.
        case skipUserStop
    }

    /// `userStopRequestedAt` and `now`: wall-clock seconds (`Date().timeIntervalSince1970`, written by
    /// the app and read by the extension, two processes with the same clock). A time in the future
    /// (clock set back) does not count.
    static func action(userStopRequestedAt: Double?, now: Double) -> Action {
        guard let userStopRequestedAt else { return .fire }
        let age = now - userStopRequestedAt
        return age >= 0 && age <= StopAlert.userStopWindow ? .skipUserStop : .fire
    }
}

/// The tap time on MirrorDrop's stop card, in the App Group (written by the app, read by the extension).
enum UserStopMark {
    static func record(now: Date = Date()) {
        AppGroup.defaults?.set(now.timeIntervalSince1970, forKey: AppGroup.userStopRequestedKey)
    }

    static func read() -> Double? {
        guard let defaults = AppGroup.defaults, defaults.object(forKey: AppGroup.userStopRequestedKey) != nil else {
            return nil
        }
        return defaults.double(forKey: AppGroup.userStopRequestedKey)
    }
}
