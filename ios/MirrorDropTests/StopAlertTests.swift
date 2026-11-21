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

    // MARK: Lock check at finish (StopAlertFinish, LockProbe)

    func testLockedAtFinishFires() {
        XCTAssertEqual(StopAlertFinish.action(probe: .locked, secondsSinceFinish: 0), .fire)
    }

    /// Readable at the end: removed like a user stop, but read again (the key outlives the lock ~10 s).
    func testUnlockedAtFinishKeepsChecking() {
        XCTAssertEqual(StopAlertFinish.action(probe: .unlocked, secondsSinceFinish: 0), .cancelAndProbeAgain)
        XCTAssertEqual(StopAlertFinish.action(probe: .unlocked, secondsSinceFinish: 9.5), .cancelAndProbeAgain)
    }

    /// The lock that ended the broadcast makes the probe fail within the window.
    func testLockFoundLaterFires() {
        XCTAssertEqual(StopAlertFinish.action(probe: .locked, secondsSinceFinish: 10.2), .fire)
    }

    /// Still readable after the window: the user stopped it.
    func testStillUnlockedAfterWindowCancels() {
        XCTAssertEqual(StopAlertFinish.action(probe: .unlocked, secondsSinceFinish: StopAlert.lockProbeWindow), .cancel)
    }

    func testNoProbeCancels() {
        XCTAssertEqual(StopAlertFinish.action(probe: .unknown, secondsSinceFinish: 0), .cancel)
    }

    /// The window covers the ~10 s key grace after a lock just before the finish.
    func testWindowCoversKeyGrace() {
        XCTAssertGreaterThan(StopAlert.lockProbeWindow, 10)
        XCTAssertLessThan(StopAlert.lockProbeInterval, 1)
        XCTAssertGreaterThan(StopAlert.lockFireDelay, 0)
    }

    func testClassifyReadErrors() {
        XCTAssertEqual(LockProbe.classify(nil), .unlocked)
        let noPermission = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(LockProbe.classify(noPermission), .locked)
        // As a locked read reports it: Cocoa error with an underlying POSIX EPERM.
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertEqual(LockProbe.classify(wrapped), .locked)
        XCTAssertEqual(LockProbe.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .locked)
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        XCTAssertEqual(LockProbe.classify(missing), .unknown)
    }
}
