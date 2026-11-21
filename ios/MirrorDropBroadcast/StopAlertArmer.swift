import Foundation
import UserNotifications

/// Extension side of the "TV 보내기가 끝났어요" dead-man notification (see Shared/StopAlert.swift).
/// While broadcasting, one pending request fires `StopAlert.fireDelay` s from now; `tick` pushes it out
/// again about every 2 s. If iOS ends the broadcast without a callback and the extension is killed or
/// suspended, nothing re-arms it and it fires. When the broadcast finishes with a callback, `finish`
/// decides at once (iOS ends the extension within about a second): the alert fires in
/// `StopAlert.finishFireDelay` s, unless the user tapped MirrorDrop's stop card in the last 30 s
/// (StopAlertFinish).
/// The extension shares the app's notification permission; the app asks for it (App/StopAlertCenter).
/// All methods are called on the pipeline queue; system callbacks hop back to it.
final class StopAlertArmer {
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private let center = UNUserNotificationCenter.current()
    private let content: UNNotificationContent = {
        let content = UNMutableNotificationContent()
        content.title = StopAlert.title
        content.body = StopAlert.body
        // No sound: the app asks for alert permission only, and the TV going dark is noticed anyway.
        return content
    }()
    private var schedule = StopAlertSchedule()
    private var active = false
    private var authorized = false
    private var checkingSettings = false
    private var lastSettingsCheck: Double?
    private var loggedNotAllowed = false
    private var loggedAddError = false

    init(queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.queue = queue
        self.log = log
    }

    /// Broadcast started: clear an old "ended" notification, check permission (arms once allowed).
    func start() {
        active = true
        schedule.reset()
        center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
        Self.removeLegacyLockProbe()
        checkSettings(now: Self.now())
    }

    /// Called from the pipeline tick (every 0.1 s); cheap unless a re-arm is due.
    func tick() {
        guard active else { return }
        let now = Self.now()
        guard authorized else {
            if !checkingSettings, now - (lastSettingsCheck ?? -.infinity) >= StopAlert.settingsRecheckInterval {
                checkSettings(now: now)
            }
            return
        }
        switch schedule.next(now: now) {
        case .none:
            return
        case .armAfterMiss:
            // The queue stalled past the fire time; the broadcast is alive, so take back the alert.
            center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
            log("stop alert re-armed late")
            arm()
        case .arm:
            arm()
        }
    }

    /// The broadcast finished with a callback: decided now, because iOS ends the extension within about
    /// a second (build 17 device log). See StopAlertFinish.
    func finish() {
        let wasActive = active
        active = false
        schedule.reset()
        guard wasActive else {
            remove()
            return
        }
        let userStopAt = UserStopMark.read()
        let now = Date().timeIntervalSince1970
        switch StopAlertFinish.action(userStopRequestedAt: userStopAt, now: now) {
        case .skipUserStop:
            remove()
            let age = userStopAt.map { String(format: "%.1f", now - $0) } ?? "?"
            log("broadcast finished: stopped from MirrorDrop \(age) s ago, stop alert removed")
        case .fire:
            guard authorized else {
                remove()
                log("broadcast finished: no stop alert (notifications not allowed)")
                return
            }
            // Replaces the pending dead-man request (same identifier).
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: StopAlert.finishFireDelay, repeats: false)
            let request = UNNotificationRequest(identifier: StopAlert.identifier, content: content, trigger: trigger)
            center.add(request) { [weak self] error in
                guard let error else { return }
                self?.queue.async { self?.log("stop alert (finish) could not be scheduled: \(error.localizedDescription)") }
            }
            log("broadcast finished: stop alert in \(Int(StopAlert.finishFireDelay)) s (no stop from MirrorDrop)")
        }
    }

    private func remove() {
        center.removePendingNotificationRequests(withIdentifiers: [StopAlert.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
    }

    /// Build 17 wrote a "lock-probe" file into the App Group; nothing reads it any more.
    private static func removeLegacyLockProbe() {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)?
            .appendingPathComponent("lock-probe") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func arm() {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: StopAlert.fireDelay, repeats: false)
        let request = UNNotificationRequest(identifier: StopAlert.identifier, content: content, trigger: trigger)
        // The same identifier replaces the pending request.
        center.add(request) { [weak self] error in
            guard let error else { return }
            self?.queue.async {
                guard let self, !self.loggedAddError else { return }
                self.loggedAddError = true
                self.log("stop alert could not be scheduled: \(error.localizedDescription)")
            }
        }
    }

    private func checkSettings(now: Double) {
        checkingSettings = true
        lastSettingsCheck = now
        center.getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            self?.queue.async {
                guard let self else { return }
                self.checkingSettings = false
                guard self.active else { return }
                if allowed, !self.authorized {
                    self.log("stop alert on")
                } else if !allowed, !self.loggedNotAllowed {
                    self.loggedNotAllowed = true
                    self.log("stop alert off: notifications not allowed")
                }
                self.authorized = allowed
            }
        }
    }

    /// Wall clock, like the notification trigger (the host clock pauses while the device sleeps).
    private static func now() -> Double {
        Date().timeIntervalSinceReferenceDate
    }
}
