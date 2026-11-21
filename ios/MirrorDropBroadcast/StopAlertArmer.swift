import Foundation
import UserNotifications

/// Extension side of the "TV 보내기가 멈췄어요" dead-man notification (see Shared/StopAlert.swift).
/// While broadcasting, one pending request fires `StopAlert.fireDelay` s from now; `tick` pushes it out
/// again about every 2 s. If iOS ends the broadcast without a callback and the extension is killed or
/// suspended, nothing re-arms it and it fires. When the broadcast finishes with a callback, `finish`
/// reads the lock probe (a file with complete data protection written by `start`): locked → the
/// alert fires in 1 s; readable → removed, and read again for a few seconds because the protection
/// key outlives the lock by about 10 s (StopAlertFinish).
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
    /// The probe file was written for this broadcast.
    private var probeWritten = false
    /// Wall-clock seconds when the broadcast finished; nil before, and after the lock check ended.
    private var finishedAt: Double?

    init(queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.queue = queue
        self.log = log
    }

    /// Broadcast started: clear an old "stopped" notification, write the lock probe, check permission
    /// (arms once allowed).
    func start() {
        active = true
        finishedAt = nil
        schedule.reset()
        center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
        writeProbe()
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

    /// The broadcast finished with a callback: by the user (no alert) or because the iPhone locked
    /// (alert). Decided by the lock probe; see StopAlertFinish.
    func finish() {
        let wasActive = active
        active = false
        schedule.reset()
        guard wasActive else {
            remove()
            return
        }
        let now = Self.now()
        finishedAt = now
        let probe = readProbe()
        log("broadcast finished (locked=\(Self.lockedText(probe)))")
        apply(StopAlertFinish.action(probe: probe, secondsSinceFinish: 0), probe: probe, elapsed: 0)
    }

    private func apply(_ action: StopAlertFinish.Action, probe: LockProbe, elapsed: Double) {
        switch action {
        case .fire:
            finishedAt = nil
            fireForLock(elapsed: elapsed)
        case .cancelAndProbeAgain:
            if elapsed == 0 {
                // Like a user stop for now; the lock that ended the broadcast shows within ~10 s.
                remove()
                log("stop alert removed; checking for a lock for \(Int(StopAlert.lockProbeWindow)) s")
            }
            queue.asyncAfter(deadline: .now() + StopAlert.lockProbeInterval) { [self] in
                probeAgain()
            }
        case .cancel:
            finishedAt = nil
            if elapsed == 0 {
                remove()
                log("stop alert removed (\(probe == .unknown ? "no lock probe" : "user stop"))")
            } else {
                log("no lock \(Int(elapsed)) s after finish: user stop, no stop alert")
            }
        }
    }

    /// Runs on the queue every `lockProbeInterval` s after the finish while the process lives.
    private func probeAgain() {
        // A new broadcast started in this process, or the check already ended.
        guard !active, let finishedAt else { return }
        let elapsed = max(0, Self.now() - finishedAt)
        let probe = readProbe()
        apply(StopAlertFinish.action(probe: probe, secondsSinceFinish: elapsed), probe: probe, elapsed: elapsed)
    }

    /// The iPhone is locked: the lock ended the broadcast. Replaces the pending request (same
    /// identifier) with one that fires in `lockFireDelay` s.
    private func fireForLock(elapsed: Double) {
        let when = elapsed == 0 ? "at finish" : String(format: "%.1f s after finish", elapsed)
        guard authorized else {
            log("stop alert not scheduled (lock \(when)): notifications not allowed")
            return
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: StopAlert.lockFireDelay, repeats: false)
        let request = UNNotificationRequest(identifier: StopAlert.identifier, content: content, trigger: trigger)
        center.add(request) { [weak self] error in
            guard let error else { return }
            self?.queue.async { self?.log("stop alert (lock) could not be scheduled: \(error.localizedDescription)") }
        }
        log("stop alert scheduled (lock \(when))")
    }

    private func remove() {
        center.removePendingNotificationRequests(withIdentifiers: [StopAlert.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [StopAlert.identifier])
    }

    // MARK: Lock probe

    private static var probeURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)?
            .appendingPathComponent(StopAlert.lockProbeFileName)
    }

    /// Complete protection: unreadable while the device is locked (after the key's ~10 s grace).
    private func writeProbe() {
        probeWritten = false
        guard let url = Self.probeURL else {
            log("lock probe: no App Group container")
            return
        }
        do {
            try Data("MirrorDrop".utf8).write(to: url, options: [.atomic, .completeFileProtection])
            probeWritten = true
        } catch {
            log("lock probe could not be written: \(error.localizedDescription)")
        }
    }

    private func readProbe() -> LockProbe {
        guard probeWritten, let url = Self.probeURL else { return .unknown }
        do {
            _ = try Data(contentsOf: url)
            return .unlocked
        } catch {
            return LockProbe.classify(error)
        }
    }

    private static func lockedText(_ probe: LockProbe) -> String {
        switch probe {
        case .locked: return "true"
        case .unlocked: return "false"
        case .unknown: return "unknown"
        }
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
