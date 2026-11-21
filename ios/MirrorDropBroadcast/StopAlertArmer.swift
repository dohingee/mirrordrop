import Foundation
import UserNotifications

/// Extension side of the "TV 보내기가 멈췄어요" dead-man notification (see Shared/StopAlert.swift).
/// While broadcasting, one pending request fires `StopAlert.fireDelay` s from now; `tick` pushes it out
/// again about every 2 s. If iOS ends the broadcast without a callback (iPhone locked) and the
/// extension is killed or suspended, nothing re-arms it and it fires. `stop` removes it.
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

    /// Broadcast started: clear an old "stopped" notification, check permission (arms once allowed).
    func start() {
        active = true
        schedule.reset()
        center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
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

    /// Broadcast ended normally (user stopped it, or our own error): nothing should fire.
    func stop() {
        active = false
        schedule.reset()
        center.removePendingNotificationRequests(withIdentifiers: [StopAlert.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
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
