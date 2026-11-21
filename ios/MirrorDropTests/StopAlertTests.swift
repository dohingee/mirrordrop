import XCTest

final class StopAlertTests: XCTestCase {
    func testFirstCallArms() {
        var schedule = StopAlertSchedule()
        XCTAssertEqual(schedule.next(now: 100), .arm)
        XCTAssertEqual(schedule.lastArmed, 100)
    }

    /// The pipeline ticks every 0.1 s; only about every 2 s re-adds the request.
    func testRearmsEveryTwoSecondsAtTickRate() {
        var schedule = StopAlertSchedule()
        var arms = 0
        for tick in 0..<100 {
            if schedule.next(now: 1000 + Double(tick) * 0.1) != .none { arms += 1 }
        }
        // 10 s of ticks: at 0, 2, 4, 6, 8 s (floating-point steps may push one tick later).
        XCTAssertEqual(arms, 5)
    }

    func testDoesNotRearmTooSoon() {
        var schedule = StopAlertSchedule()
        _ = schedule.next(now: 10)
        XCTAssertEqual(schedule.next(now: 11.9), .none)
        XCTAssertEqual(schedule.lastArmed, 10)
        XCTAssertEqual(schedule.next(now: 12), .arm)
    }

    /// The pending notification always stays at least fireDelay - rearmInterval in the future.
    func testDelayLeavesMarginOverRearm() {
        XCTAssertGreaterThan(StopAlert.fireDelay, StopAlert.rearmInterval * 2)
    }

    /// A late re-arm (queue stalled past the fire time) means the notification probably fired
    /// while the broadcast was still alive.
    func testLateRearmClearsDelivered() {
        var schedule = StopAlertSchedule()
        _ = schedule.next(now: 10)
        XCTAssertEqual(schedule.next(now: 10 + StopAlert.fireDelay), .armAfterMiss)
        XCTAssertEqual(schedule.next(now: 10 + StopAlert.fireDelay + 2), .arm)
    }

    func testClockSetBackwardsRearms() {
        var schedule = StopAlertSchedule()
        _ = schedule.next(now: 100)
        XCTAssertEqual(schedule.next(now: 50), .arm)
        XCTAssertEqual(schedule.lastArmed, 50)
    }

    func testResetArmsAtNextStart() {
        var schedule = StopAlertSchedule()
        _ = schedule.next(now: 10)
        schedule.reset()
        XCTAssertNil(schedule.lastArmed)
        XCTAssertEqual(schedule.next(now: 10.5), .arm)
    }

    func testFixedIdentifier() {
        XCTAssertEqual(StopAlert.identifier, "mirrordrop.broadcast-stopped")
    }

    // MARK: When the broadcast finishes (StopAlertFinish)

    /// No tap on MirrorDrop's stop card: a lock or a stop from the red indicator in another app.
    func testFinishWithoutUserStopFires() {
        XCTAssertEqual(StopAlertFinish.action(userStopRequestedAt: nil, now: 1000), .fire)
    }

    func testRecentUserStopSkips() {
        XCTAssertEqual(StopAlertFinish.action(userStopRequestedAt: 995, now: 1000), .skipUserStop)
        XCTAssertEqual(StopAlertFinish.action(userStopRequestedAt: 1000, now: 1000), .skipUserStop)
        XCTAssertEqual(StopAlertFinish.action(userStopRequestedAt: 1000 - StopAlert.userStopWindow, now: 1000),
                       .skipUserStop)
    }

    /// A tap long ago (an earlier broadcast, or the sheet was cancelled) does not hide the alert.
    func testOldUserStopFires() {
        XCTAssertEqual(StopAlertFinish.action(userStopRequestedAt: 1000 - StopAlert.userStopWindow - 0.1, now: 1000),
                       .fire)
        XCTAssertEqual(StopAlertFinish.action(userStopRequestedAt: 0, now: 1000), .fire)
    }

    /// A time in the future (clock set back after the tap) does not count.
    func testFutureUserStopFires() {
        XCTAssertEqual(StopAlertFinish.action(userStopRequestedAt: 1005, now: 1000), .fire)
    }

    /// Scheduled at once and short: iOS ends the extension within about a second of the finish, and the
    /// app in front still has time to take it back; the window covers the system sheet.
    func testFinishTimings() {
        XCTAssertGreaterThan(StopAlert.finishFireDelay, 0)
        XCTAssertLessThanOrEqual(StopAlert.finishFireDelay, 3)
        XCTAssertGreaterThanOrEqual(StopAlert.userStopWindow, 10)
    }
}
