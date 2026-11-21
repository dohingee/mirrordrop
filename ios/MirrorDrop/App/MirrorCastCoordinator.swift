import Combine
import UIKit

/// Sends the mirror stream to the TV once it is ready, and clears the TV when the broadcast ends.
/// Lives outside the views so it also runs while the app is in the background: SwiftUI `onChange`
/// is not guaranteed to run then.
///
/// The extension needs a few seconds after the user taps start before the stream is ready, and
/// only the app can send the play request (the Cast SDK is too big for the extension). Users often
/// switch to another app right away; iOS then suspends this app within seconds. So while a play
/// request is still to come, the app holds a finite-length background task (`beginBackgroundTask`,
/// about 30 s, iOS decides) and ends it as soon as the TV answered, the broadcast ended or iOS
/// asks. No background mode (docs/SPEC.md 8). Decisions: Shared/BackgroundCastHold.swift.
///
/// Limit: a suspended app runs no code. A new address after a Wi-Fi change (`urlRevision`) while
/// the app is already suspended is only sent when the user returns to the app; this helps only
/// when the app is still awake (it left the front moments ago, or still holds its task).
final class MirrorCastCoordinator: NSObject {
    static let shared = MirrorCastCoordinator()

    private let cast = CastManager.shared
    private let monitor = BroadcastMonitor.shared
    private var trigger = AutoCastTrigger()
    private var wasLive = false
    private var inBackground = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// Stream state when iOS ended our task: no new task for the same state (it would only be
    /// ended again); a new stream, revision or connection may start one.
    private var expiredKey: AutoCastTrigger.Key?
    private var currentKey: AutoCastTrigger.Key?
    private var updateScheduled = false
    private var subscriptions = Set<AnyCancellable>()
    private var isStarted = false

    /// Called once at launch, after CastManager.setUp().
    func start() {
        guard !isStarted else { return }
        isStarted = true
        inBackground = UIApplication.shared.applicationState == .background
        // objectWillChange fires before the new value is stored, so evaluate on the next main-queue
        // turn (coalesced: many changes, one update).
        Publishers.Merge(monitor.objectWillChange, cast.objectWillChange)
            .sink { [weak self] _ in self?.scheduleUpdate() }
            .store(in: &subscriptions)
        // Selector observers run synchronously on the posting (main) thread, so the task begins
        // inside the didEnterBackground callback, before iOS can suspend the app.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        update()
    }

    @objc private func didEnterBackground() {
        inBackground = true
        // Fresh status first: the 1 s poll may not have seen the latest extension state.
        monitor.reload()
        update()
    }

    @objc private func willEnterForeground() {
        inBackground = false
        expiredKey = nil
        update()
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func update() {
        let live = monitor.isLive
        // Broadcast ended or the extension died: clear the TV instead of leaving it spinning.
        if wasLive, !live { cast.stopMirror() }
        wasLive = live

        // Automatic cast: a new ready stream, revision (Wi-Fi change) or connection. CastManager
        // forgets the sent URL on disconnect, so a reconnect sends it again.
        let url = monitor.readyURL
        let revision = monitor.status.urlRevision
        let connected = cast.isConnected
        if trigger.shouldCast(url: url?.absoluteString, revision: revision, connected: connected), let url {
            cast.castMirror(url, revision: revision, force: false)
        }

        let key = AutoCastTrigger.Key(url: url?.absoluteString, revision: revision, connected: connected)
        currentKey = key
        let link: BackgroundCastHold.Link
        switch cast.connection {
        case .connected: link = .connected
        case .connecting: link = .connecting
        case .noDevices, .notConnected: link = .none
        }
        let input = BackgroundCastHold.Input(
            inBackground: inBackground, broadcastLive: live, link: link, streamReady: url != nil,
            autoCastDone: trigger.isDone(url: url?.absoluteString, revision: revision, connected: connected),
            loadInFlight: cast.isLoadPending)
        updateBackgroundTask(input, key: key)
    }

    private func updateBackgroundTask(_ input: BackgroundCastHold.Input, key: AutoCastTrigger.Key) {
        if let release = BackgroundCastHold.release(for: input) {
            if backgroundTask != .invalid { endBackgroundTask(reason: release.rawValue) }
            return
        }
        guard backgroundTask == .invalid, expiredKey != key else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "MirrorDrop.sendToTV") { [weak self] in
            // iOS's time is up (called on the main thread): end now or iOS ends the app.
            guard let self else { return }
            self.expiredKey = self.currentKey
            self.endBackgroundTask(reason: "expired")
        }
        guard task != .invalid else {
            cast.logEvent("background task begin failed (no background time left)")
            return
        }
        backgroundTask = task
        let why = !input.streamReady ? "waiting for stream"
            : input.link == .connecting ? "waiting for TV connection"
            : "sending play request"
        cast.logEvent("background task begin (\(why))")
    }

    private func endBackgroundTask(reason: String) {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        cast.logEvent("background task end (\(reason))")
        UIApplication.shared.endBackgroundTask(task)
    }
}
