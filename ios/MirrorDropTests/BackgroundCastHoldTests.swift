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

