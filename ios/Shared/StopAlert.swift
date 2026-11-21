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

// MARK: Lock check when the broadcast finishes

/// Locking the iPhone ends the broadcast, and iOS then calls `broadcastFinished` like a user stop
/// (build 16: the stop path removed the alert, so it never appeared). To tell the two apart, the
/// extension writes a tiny file with complete data protection (`Data.WritingOptions
/// .completeFileProtection`) when the broadcast starts and tries to read it when it finishes: a
/// protection (permission) error means the device is locked.
///
/// Grace period: iOS discards the key of that protection class about 10 s after the lock (when
/// "Require Password" is "Immediately", always the case with Face ID / Touch ID; Apple Platform
/// Security, "Data Protection classes"). The lock comes just before the broadcast ends, so a read
/// right at the end still succeeds. So after a readable first read the extension removes the alert
/// (as for a user stop) and keeps reading every `lockProbeInterval` for `lockProbeWindow` s after
/// the end: the lock that ended the broadcast makes a read fail within about 10 s, while a user who
/// stopped and locks later makes it fail only 10 s after that later lock. Limits (docs/POC_TEST.md):
/// the extension process must live that long after `broadcastFinished`; a user who locks within
/// about 1 s of stopping gets the alert too; without a passcode the file never locks (no alert).
extension StopAlert {
    /// File name of the probe in the App Group container.
    static let lockProbeFileName = "lock-probe"
    /// The alert fires this long after the lock was detected (must be > 0 for the trigger).
    static let lockFireDelay: TimeInterval = 1
    /// How long after the end the extension keeps reading the probe (10 s key grace + margin).
    static let lockProbeWindow: TimeInterval = 11
    static let lockProbeInterval: TimeInterval = 0.5
}

/// Result of reading the probe file.
enum LockProbe: String, Equatable {
    /// Read: the device is unlocked (or locked less than about 10 s ago).
    case unlocked
    /// Protection error: the device is locked.
    case locked
    /// No probe (not written, other error): cannot tell.
    case unknown

    /// Classifies the error of reading the probe (nil: read fine). A read of a protected file while
    /// locked fails with NSFileReadNoPermissionError (257), underlying POSIX EPERM / EACCES.
    static func classify(_ error: Error?) -> LockProbe {
        guard let error else { return .unlocked }
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return .locked }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
                return .locked
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unknown
    }
}

/// What the extension does with the alert when the broadcast has finished. Pure logic, tested in
/// StopAlertTests.
enum StopAlertFinish {
    enum Action: Equatable {
        /// Locked: the lock ended the broadcast. Schedule the alert in `StopAlert.lockFireDelay` s.
        case fire
        /// Readable so far: no alert now (removed like a user stop), read again in
        /// `StopAlert.lockProbeInterval` s.
        case cancelAndProbeAgain
        /// User stop (still readable at the end of the window) or no probe: no alert, stop reading.
        case cancel
    }

    static func action(probe: LockProbe, secondsSinceFinish: Double) -> Action {
        switch probe {
        case .locked: return .fire
        case .unknown: return .cancel
        case .unlocked:
            return secondsSinceFinish < StopAlert.lockProbeWindow ? .cancelAndProbeAgain : .cancel
        }
    }
}
