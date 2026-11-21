import XCTest

final class AdPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    /// Every interstitial condition met (4 broadcasts done, no ad before, no restart).
    private func eligible() -> AdPolicy.Input {
        AdPolicy.Input(isSending: false, isDemo: false, showsTroubleshooting: false, broadcastsStarted: 4,
                       lastInterstitialAt: nil, restartSignalAt: nil, now: now)
    }

    // MARK: Banner

    func testBannerOnIdleMainScreen() {
        XCTAssertTrue(AdPolicy.showsBanner(eligible()))
        // The banner does not wait for the first broadcasts.
        var input = eligible()
        input.broadcastsStarted = 0
        XCTAssertTrue(AdPolicy.showsBanner(input))
    }

    func testNoBannerWhileSending() {
        var input = eligible()
        input.isSending = true
        XCTAssertFalse(AdPolicy.showsBanner(input))
    }

    func testNoBannerInDemo() {
        var input = eligible()
        input.isDemo = true
        XCTAssertFalse(AdPolicy.showsBanner(input))
    }

    func testNoBannerOverTVNotFoundHelp() {
        var input = eligible()
        input.showsTroubleshooting = true
        XCTAssertFalse(AdPolicy.showsBanner(input))
    }

    func testBannerStaysDuringRestart() {
        // Only the interstitial and the prompts step back for a restart; the banner is not in the way.
        var input = eligible()
        input.restartSignalAt = now
        XCTAssertTrue(AdPolicy.showsBanner(input))
    }

    // MARK: Interstitial

    func testInterstitialWhenAllConditionsHold() {
        XCTAssertTrue(AdPolicy.interstitialEligible(eligible()))
        XCTAssertTrue(AdPolicy.armsInterstitial(eligible(), adLoaded: true))
    }

    func testInterstitialOnlyWhenLoaded() {
        XCTAssertFalse(AdPolicy.armsInterstitial(eligible(), adLoaded: false))
    }

    func testNoInterstitialWhileSending() {
        var input = eligible()
        input.isSending = true
        XCTAssertFalse(AdPolicy.interstitialEligible(input))
        XCTAssertFalse(AdPolicy.armsInterstitial(input, adLoaded: true))
    }

    func testNoInterstitialInDemo() {
        var input = eligible()
        input.isDemo = true
        XCTAssertFalse(AdPolicy.armsInterstitial(input, adLoaded: true))
    }

    func testNoInterstitialForFirstThreeBroadcasts() {
        var input = eligible()
        for started in 0..<AdPolicy.freeBroadcasts {
            input.broadcastsStarted = started
            XCTAssertFalse(AdPolicy.interstitialEligible(input), "broadcasts started: \(started)")
        }
        // Before the 4th start, 3 broadcasts have been started.
        input.broadcastsStarted = 3
        XCTAssertTrue(AdPolicy.interstitialEligible(input))
    }

    func testAtMostOncePerDay() {
        var input = eligible()
        input.lastInterstitialAt = now.addingTimeInterval(-day + 1)
        XCTAssertFalse(AdPolicy.interstitialEligible(input))
        input.lastInterstitialAt = now.addingTimeInterval(-60)
        XCTAssertFalse(AdPolicy.interstitialEligible(input))
        input.lastInterstitialAt = now.addingTimeInterval(-day)
        XCTAssertTrue(AdPolicy.interstitialEligible(input))
        input.lastInterstitialAt = now.addingTimeInterval(-3 * day)
        XCTAssertTrue(AdPolicy.interstitialEligible(input))
    }

    func testClockTurnedBackDoesNotBlockForever() {
        var input = eligible()
        input.lastInterstitialAt = now.addingTimeInterval(30 * day)
        XCTAssertTrue(AdPolicy.interstitialEligible(input))
        // A few seconds of skew still counts as "just shown".
        input.lastInterstitialAt = now.addingTimeInterval(10)
        XCTAssertFalse(AdPolicy.interstitialEligible(input))
    }

    func testNoInterstitialWithinTenMinutesOfRestartSignal() {
        var input = eligible()
        input.restartSignalAt = now
        XCTAssertFalse(AdPolicy.interstitialEligible(input))
        input.restartSignalAt = now.addingTimeInterval(-(AdPolicy.restartWindow - 1))
        XCTAssertFalse(AdPolicy.interstitialEligible(input))
        input.restartSignalAt = now.addingTimeInterval(-AdPolicy.restartWindow)
        XCTAssertTrue(AdPolicy.interstitialEligible(input))
    }

    func testRestartSignalFromTheFutureIsIgnored() {
        var input = eligible()
        input.restartSignalAt = now.addingTimeInterval(day)
        XCTAssertFalse(AdPolicy.isRestarting(input))
        XCTAssertTrue(AdPolicy.interstitialEligible(input))
    }

    func testWindowsMatchMonetizationDoc() {
        XCTAssertEqual(AdPolicy.freeBroadcasts, 3)
        XCTAssertEqual(AdPolicy.interstitialInterval, day)
        XCTAssertEqual(AdPolicy.restartWindow, 600)
    }

    // MARK: Consent and tracking prompt

    func testNoPromptsBeforeFirstBroadcast() {
        var input = eligible()
        input.broadcastsStarted = 0
        XCTAssertFalse(AdPolicy.asksConsent(input))
        input.broadcastsStarted = 1
        XCTAssertTrue(AdPolicy.asksConsent(input))
    }

    func testNoPromptsWhileSendingInDemoOrRestarting() {
        var sending = eligible()
        sending.isSending = true
        XCTAssertFalse(AdPolicy.asksConsent(sending))
        var demo = eligible()
        demo.isDemo = true
        XCTAssertFalse(AdPolicy.asksConsent(demo))
        var restarting = eligible()
        restarting.restartSignalAt = now.addingTimeInterval(-30)
        XCTAssertFalse(AdPolicy.asksConsent(restarting))
    }

    // MARK: Broadcast counting

    func testEachBroadcastCountedOnce() {
        var history = AdHistory()
        let first = now
        XCTAssertTrue(history.registerBroadcast(startedAt: first))
        // Polling and relaunches see the same status again.
        XCTAssertFalse(history.registerBroadcast(startedAt: first))
        XCTAssertFalse(history.registerBroadcast(startedAt: nil))
        XCTAssertTrue(history.registerBroadcast(startedAt: first.addingTimeInterval(120)))
        XCTAssertEqual(history.broadcastsStarted, 2)
    }

    func testOlderStatusIsNotCounted() {
        var history = AdHistory()
        history.registerBroadcast(startedAt: now)
        XCTAssertFalse(history.registerBroadcast(startedAt: now.addingTimeInterval(-60)))
        XCTAssertEqual(history.broadcastsStarted, 1)
    }

    func testHistoryRoundTrips() throws {
        var history = AdHistory()
        history.registerBroadcast(startedAt: now)
        history.lastInterstitialAt = now
        history.stopAlertOpenedAt = now.addingTimeInterval(-5)
        let decoded = try JSONDecoder().decode(AdHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }

    // MARK: Ad units

    private let live = AdUnits(banner: "ca-app-pub-7472495816861016/6198853395",
                               interstitial: "ca-app-pub-7472495816861016/5128033043")

    func testLiveUnitsOnlyInAppStoreDownload() {
        XCTAssertEqual(AdUnits.choose(configured: live, isTestBuild: false, store: .appStore), live)
        XCTAssertEqual(AdUnits.choose(configured: live, isTestBuild: false, store: .sandbox), .test)
        XCTAssertEqual(AdUnits.choose(configured: live, isTestBuild: false, store: .unknown), .test)
        XCTAssertEqual(AdUnits.choose(configured: live, isTestBuild: true, store: .appStore), .test)
    }

    func testUnconfiguredUnitsFallBackToTest() {
        let missing = AdUnits(banner: "$(ADMOB_BANNER)", interstitial: "")
        XCTAssertFalse(missing.isLive)
        XCTAssertFalse(AdUnits.test.isLive)
        XCTAssertTrue(live.isLive)
        XCTAssertEqual(AdUnits.choose(configured: missing, isTestBuild: false, store: .appStore), .test)
    }
}
