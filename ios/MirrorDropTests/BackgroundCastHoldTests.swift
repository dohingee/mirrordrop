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
}
