import XCTest

final class BackgroundCastHoldTests: XCTestCase {
    private func input(inBackground: Bool = true, live: Bool = true, link: BackgroundCastHold.Link = .connected,
                       ready: Bool = false, done: Bool = false, inFlight: Bool = false) -> BackgroundCastHold.Input {
        BackgroundCastHold.Input(inBackground: inBackground, broadcastLive: live, link: link,
                                 streamReady: ready, autoCastDone: done, loadInFlight: inFlight)
    }

    /// The reported bug: start, leave the app at once, the stream is not ready yet.
    func testHoldsWhileStreamNotReady() {
        XCTAssertNil(BackgroundCastHold.release(for: input(ready: false)))
    }

    func testHoldsWhileReadyButNotSent() {
        XCTAssertNil(BackgroundCastHold.release(for: input(ready: true, done: false)))
    }

    func testHoldsUntilTheTVAnswers() {
        XCTAssertNil(BackgroundCastHold.release(for: input(ready: true, done: true, inFlight: true)))
        XCTAssertEqual(BackgroundCastHold.release(for: input(ready: true, done: true, inFlight: false)), .delivered)
    }

    func testHoldsWhileConnecting() {
        XCTAssertNil(BackgroundCastHold.release(for: input(link: .connecting, ready: true)))
    }

    func testReleases() {
        XCTAssertEqual(BackgroundCastHold.release(for: input(inBackground: false)), .foreground)
        XCTAssertEqual(BackgroundCastHold.release(for: input(live: false)), .notLive)
        XCTAssertEqual(BackgroundCastHold.release(for: input(link: .none)), .noTV)
    }

    /// Foreground wins over everything (no background task while the app is in front).
    func testForegroundAlwaysReleases() {
        XCTAssertEqual(BackgroundCastHold.release(for: input(inBackground: false, ready: true, inFlight: true)),
                       .foreground)
    }

    // MARK: AutoCastTrigger

    func testCastsOnceWhenReadyAndConnected() {
        var trigger = AutoCastTrigger()
        XCTAssertFalse(trigger.shouldCast(url: nil, revision: 0, connected: true))
        XCTAssertTrue(trigger.shouldCast(url: "a", revision: 0, connected: true))
        XCTAssertFalse(trigger.shouldCast(url: "a", revision: 0, connected: true))
        XCTAssertTrue(trigger.isDone(url: "a", revision: 0, connected: true))
    }

    func testWaitsForConnection() {
        var trigger = AutoCastTrigger()
        XCTAssertFalse(trigger.shouldCast(url: "a", revision: 0, connected: false))
        XCTAssertFalse(trigger.isDone(url: "a", revision: 0, connected: false))
        XCTAssertTrue(trigger.shouldCast(url: "a", revision: 0, connected: true))
    }

    /// Wi-Fi change or outage: same or new URL text with a new revision is sent again.
    func testNewRevisionCastsAgain() {
        var trigger = AutoCastTrigger()
        _ = trigger.shouldCast(url: "a", revision: 0, connected: true)
        XCTAssertFalse(trigger.isDone(url: "a", revision: 1, connected: true))
        XCTAssertTrue(trigger.shouldCast(url: "a", revision: 1, connected: true))
    }

    func testReconnectCastsAgain() {
        var trigger = AutoCastTrigger()
        _ = trigger.shouldCast(url: "a", revision: 0, connected: true)
        XCTAssertFalse(trigger.shouldCast(url: "a", revision: 0, connected: false))
        XCTAssertTrue(trigger.shouldCast(url: "a", revision: 0, connected: true))
    }

    /// The reason of every automatic send goes to the Cast events and the startup / resend records.
    func testCastReasons() {
        var trigger = AutoCastTrigger()
        XCTAssertNil(trigger.castReason(url: nil, revision: 0, connected: true))
        XCTAssertEqual(trigger.castReason(url: "a", revision: 0, connected: true), .autoStreamReady)
        XCTAssertNil(trigger.castReason(url: "a", revision: 0, connected: true))
        XCTAssertNil(trigger.castReason(url: "a", revision: 0, connected: false))
        XCTAssertEqual(trigger.castReason(url: "a", revision: 0, connected: true), .autoConnected)
        XCTAssertEqual(trigger.castReason(url: "b", revision: 1, connected: true), .autoNewAddress)
        XCTAssertEqual(trigger.castReason(url: "b", revision: 2, connected: true), .autoNewRevision)

        // Broadcast started before a TV was chosen: the stream was ready first, then the TV connected.
        var late = AutoCastTrigger()
        XCTAssertNil(late.castReason(url: "a", revision: 0, connected: false))
        XCTAssertEqual(late.castReason(url: "a", revision: 0, connected: true), .autoConnected)
    }
}

final class MirrorReloadPolicyTests: XCTestCase {
    private func decide(force: Bool = false, _ tv: MirrorReloadPolicy.TVStatus,
                        mayWait: Bool = true) -> MirrorReloadPolicy.Decision {
        MirrorReloadPolicy.decide(url: "http://10.0.0.2:8765/t/live.m3u8", force: force, tv: tv, mayWait: mayWait)
    }

    private let same = "http://10.0.0.2:8765/t/live.m3u8"

    /// Build 16: the TV played the stream and got it again (screen off and on, reconnect).
    func testSkipsWhileTVPlaysTheSameStream() {
        for phase in [PlaybackTrace.Phase.playing, .buffering, .paused, .loading] {
            XCTAssertEqual(decide(.known(contentURL: same, phase: phase)), .skip, "\(phase)")
        }
    }

    func testLoadsWhenTVStoppedOrPlaysSomethingElse() {
        XCTAssertEqual(decide(.known(contentURL: same, phase: .idle)), .load)
        XCTAssertEqual(decide(.known(contentURL: same, phase: .unknown)), .load)
        XCTAssertEqual(decide(.known(contentURL: "http://10.0.0.3:8765/t/live.m3u8", phase: .playing)), .load)
        XCTAssertEqual(decide(.known(contentURL: nil, phase: .playing)), .load)
    }

    func testForcedSendAlwaysLoads() {
        XCTAssertEqual(decide(force: true, .known(contentURL: same, phase: .playing)), .load)
        XCTAssertEqual(decide(force: true, .unknown), .load)
    }

    /// A resumed session has no media status at first: wait for one, then load if still none.
    func testWaitsForStatusOnce() {
        XCTAssertEqual(decide(.unknown), .waitForStatus)
        XCTAssertEqual(decide(.unknown, mayWait: false), .load)
    }
}


final class MirrorStopPolicyTests: XCTestCase {
    private func decide(live: Bool = false, pending: Bool = true, connected: Bool = true,
                        tv: MirrorStopPolicy.TVStatus, since: Double? = nil) -> MirrorStopPolicy.Decision {
        MirrorStopPolicy.decide(broadcastLive: live, pending: pending, connected: connected, tv: tv,
                                secondsSinceLastRequest: since)
    }

    /// The broadcast ended and the TV still plays or buffers our stream: stop it.
    func testStopsOurStreamAfterTheEnd() {
        XCTAssertEqual(decide(tv: .ours(.playing)), .stop)
        XCTAssertEqual(decide(tv: .ours(.buffering)), .stop)
        XCTAssertEqual(decide(tv: .ours(.loading)), .stop)
        XCTAssertEqual(decide(tv: .ours(.paused)), .stop)
        XCTAssertEqual(decide(tv: .ours(.unknown)), .stop)
    }

    /// Build 17 device: the app came back, the TV still buffered our dead stream (no pending intent
    /// after a relaunch, or a resumed session): stopped too.
    func testStopsOurStreamWithoutPendingIntent() {
        XCTAssertEqual(decide(pending: false, tv: .ours(.buffering)), .stop)
    }

    /// Session suspended, reconnecting or gone: keep the intent, send once it is back.
    func testWaitsForTheSession() {
        XCTAssertEqual(decide(connected: false, tv: .ours(.buffering)), .none)
        XCTAssertEqual(decide(connected: false, tv: .unknown), .none)
        XCTAssertEqual(decide(connected: true, tv: .ours(.buffering)), .stop)
    }

    /// The stop went into a dead socket: the next status (TV still buffering) sends it again, but not
    /// on every status update.
    func testResendsAfterInterval() {
        XCTAssertEqual(decide(tv: .ours(.buffering), since: 1), .none)
        XCTAssertEqual(decide(tv: .ours(.buffering), since: MirrorStopPolicy.resendInterval), .stop)
        // A clock that went backwards does not block.
        XCTAssertEqual(decide(tv: .ours(.buffering), since: -3), .stop)
    }

    func testClearedWhenTVIdleOrOtherMedia() {
        XCTAssertEqual(decide(tv: .ours(.idle)), .cleared)
        XCTAssertEqual(decide(tv: .notOurs), .cleared)
        XCTAssertEqual(decide(pending: false, tv: .ours(.idle)), .none)
        XCTAssertEqual(decide(pending: false, tv: .notOurs), .none)
    }

    /// Never stops media that is not ours.
    func testNeverStopsOtherMedia() {
        XCTAssertNotEqual(decide(tv: .notOurs), .stop)
        XCTAssertNotEqual(decide(pending: false, tv: .notOurs), .stop)
    }

    func testAsksForStatusWhenUnknown() {
        XCTAssertEqual(decide(tv: .unknown), .askStatus)
        XCTAssertEqual(decide(tv: .unknown, since: 1), .none)
        XCTAssertEqual(decide(pending: false, tv: .unknown), .none)
    }

    /// A new broadcast is live: nothing is stopped, a pending clear is dropped.
    func testLiveBroadcastCancels() {
        XCTAssertEqual(decide(live: true, tv: .ours(.playing)), .cancel)
        XCTAssertEqual(decide(live: true, pending: false, tv: .ours(.playing)), .none)
    }

    func testMirrorIdentification() {
        let tokens: Set<String> = ["abc123"]
        XCTAssertTrue(MirrorStopPolicy.isMirror("http://192.168.0.5:8765/abc123/live.m3u8", tokens: tokens))
        XCTAssertFalse(MirrorStopPolicy.isMirror("http://192.168.0.5:8765/other/live.m3u8", tokens: tokens))
        XCTAssertFalse(MirrorStopPolicy.isMirror("https://example.com/abc123", tokens: tokens))
        XCTAssertFalse(MirrorStopPolicy.isMirror(nil, tokens: tokens))
        XCTAssertFalse(MirrorStopPolicy.isMirror("not a url", tokens: tokens))
        XCTAssertEqual(MirrorStopPolicy.token(of: "http://10.0.0.2:8765/t0k/live.m3u8"), "t0k")
    }
}
