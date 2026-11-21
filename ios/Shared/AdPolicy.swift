import Foundation

/// When ads may show (docs/MONETIZATION.md "광고를 어디에 언제 보여 주나"). Pure logic, tested in
/// AdPolicyTests; the app side (Google Mobile Ads, consent, the views) is App/AdsManager.swift.
///
/// While sending, the whole iPhone screen goes to the TV, so no ad may be on screen then. Ads exist
/// only in the app, never in the broadcast extension (App Store guideline 2.5.18). This file is in
/// Shared/ only so the unit tests can compile it; it links nothing and the extension never calls it.
enum AdPolicy {
    /// No interstitial for the first broadcasts after install (first impression).
    static let freeBroadcasts = 3
    /// At most one interstitial per this interval.
    static let interstitialInterval: TimeInterval = 24 * 60 * 60
    /// After the stop notification was opened or a broadcast ended unexpectedly, the user is restarting:
    /// no interstitial and no consent / tracking prompts for this long.
    static let restartWindow: TimeInterval = 10 * 60
    /// A timestamp further in the future than this (the clock was turned back) is ignored, so a wrong
    /// clock can never block ads or prompts for a long time.
    static let clockSkewTolerance: TimeInterval = 60

    struct Input: Equatable {
        /// The broadcast is starting or live: the screen goes to the TV (BroadcastMonitor.isLive).
        var isSending = false
        /// Store screenshot demo (App/DemoMode.swift): never any ad or prompt.
        var isDemo = false
        /// The "TV를 찾지 못했어요" help is on the main screen: the user is solving a problem.
        var showsTroubleshooting = false
        /// Broadcasts started since install (AdHistory).
        var broadcastsStarted = 0
        var lastInterstitialAt: Date?
        /// Latest of: the stop notification was opened, the broadcast stopped unexpectedly or failed.
        var restartSignalAt: Date?
        var now = Date()
    }

    /// The bottom banner on the main screen. False removes the ad view from the screen entirely.
    static func showsBanner(_ input: Input) -> Bool {
        !input.isDemo && !input.isSending && !input.showsTroubleshooting
    }

    /// The user is restarting after a stop (notification tap, unexpected stop or failure, recently).
    static func isRestarting(_ input: Input) -> Bool {
        guard let signal = input.restartSignalAt else { return false }
        let age = input.now.timeIntervalSince(signal)
        return age >= -clockSkewTolerance && age < restartWindow
    }

    /// Whether an interstitial may be shown before the next start (conditions 1-4 of MONETIZATION.md).
    /// The app loads one only while this is true, so no ad is requested that could not be shown.
    static func interstitialEligible(_ input: Input) -> Bool {
        guard !input.isDemo, !input.isSending else { return false }
        guard input.broadcastsStarted >= freeBroadcasts else { return false }
        guard !isRestarting(input) else { return false }
        if let last = input.lastInterstitialAt {
            let age = input.now.timeIntervalSince(last)
            // A "last shown" in the future means the clock went back: ignore it.
            if age >= -clockSkewTolerance && age < interstitialInterval { return false }
        }
        return true
    }

    /// Decided BEFORE the tap (condition 5): only with a loaded ad does the start card become a button
    /// that shows the ad; otherwise it is the system broadcast picker, which starts right away.
    static func armsInterstitial(_ input: Input, adLoaded: Bool) -> Bool {
        adLoaded && interstitialEligible(input)
    }

    /// A calm moment for Google's consent form and then Apple's tracking prompt: after the first
    /// broadcast finished, never while sending, never in the first-launch TV setup, never over a
    /// restart after a stop.
    static func asksConsent(_ input: Input) -> Bool {
        !input.isDemo && !input.isSending && input.broadcastsStarted >= 1 && !isRestarting(input)
    }
}

/// What the ad rules remember across launches (stored by App/AdsManager.swift in UserDefaults).
struct AdHistory: Codable, Equatable {
    /// Broadcasts started since install.
    var broadcastsStarted = 0
    /// `BroadcastStatus.startedAt` of the last counted broadcast: each broadcast has its own start
    /// time, so one seen again (polling, relaunch) is not counted twice.
    var lastCountedStart: Date?
    var lastInterstitialAt: Date?
    /// When the "TV 보내기가 끝났어요" notification was opened.
    var stopAlertOpenedAt: Date?

    /// Counts a broadcast the first time its start time is seen. Also counts one that started while
    /// the app was not running (seen at the next launch). Returns true when it counted.
    @discardableResult
    mutating func registerBroadcast(startedAt: Date?) -> Bool {
        guard let startedAt else { return false }
        if let last = lastCountedStart, startedAt <= last { return false }
        lastCountedStart = startedAt
        broadcastsStarted += 1
        return true
    }
}

/// Which ad units a build uses. Google's test units in every test build (Debug, simulator) and in
/// TestFlight / App Review (StoreKit sandbox): the owner and the reviewers never see or tap live ads,
/// which AdMob counts as invalid traffic. Live units only in an App Store download.
struct AdUnits: Equatable {
    var banner: String
    var interstitial: String

    /// Google's sample publisher: every official test app and ad unit ID uses it.
    static let testPublisher = "ca-app-pub-3940256099942544"
    /// https://developers.google.com/admob/ios/banner and /interstitial (test ad units).
    static let test = AdUnits(banner: "ca-app-pub-3940256099942544/2435281174",
                              interstitial: "ca-app-pub-3940256099942544/4411468910")

    /// Real IDs present (not empty, not an unexpanded build setting, not Google's test publisher).
    var isLive: Bool {
        [banner, interstitial].allSatisfy { id in
            id.hasPrefix("ca-app-pub-") && !id.contains("$(") && !id.hasPrefix(Self.testPublisher)
        }
    }

    /// Where the running app came from (StoreKit `AppTransaction.environment`).
    enum Store: Equatable { case appStore, sandbox, unknown }

    static func choose(configured: AdUnits, isTestBuild: Bool, store: Store) -> AdUnits {
        guard !isTestBuild, store == .appStore, configured.isLive else { return .test }
        return configured
    }
}
