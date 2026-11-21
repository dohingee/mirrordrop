import AppTrackingTransparency
import Combine
import GoogleMobileAds
import SwiftUI
import UserMessagingPlatform

/// AdMob in the app (never in the broadcast extension): the main screen's bottom banner and one
/// interstitial before a start. Rules: docs/MONETIZATION.md; decisions: Shared/AdPolicy.swift.
///
/// - No ad is on screen while sending (the whole screen goes to the TV): the banner view is removed
///   then, and the interstitial only ever shows before the system broadcast sheet opens.
/// - The interstitial is decided before the tap: with a loaded ad and every condition met, the start
///   card is a plain button that shows the ad; afterwards the card is the system picker again and says
///   "이제 눌러서 시작하세요". The picker's internal button is never triggered from code (2.5.1).
/// - Consent: at launch only Google's consent status is refreshed (no form over the first TV setup).
///   Google's form (UMP: GDPR regions, the IDFA explainer if published in AdMob) and then Apple's
///   tracking prompt come at a calm moment: the app is in front after the first broadcast ended, not
///   while sending or connecting, not over a restart (AdPolicy.asksConsent). The SDK starts and ads
///   are requested only while `canRequestAds`. Refusing changes nothing in the app.
/// - Demo mode (store screenshots): nothing starts, so no ad, form or prompt.
/// - Ad units: Google's test units in Debug / simulator builds and in TestFlight / App Review; the
///   live units (ios/project.yml) only in App Store downloads (AdUnits.choose, AdStoreEnvironment).
@MainActor
final class AdsManager: ObservableObject {
    static let shared = AdsManager()

    /// The SDK has started with consent: banners may be created.
    @Published private(set) var adsReady = false
    /// The start card shows the interstitial first (decided before the tap).
    @Published private(set) var interstitialArmed = false
    /// After the interstitial closed: the start card is outlined and says "이제 눌러서 시작하세요".
    @Published private(set) var startPrompt = false
    /// "광고 개인정보 설정" is offered (Google: only when the privacy options are required).
    @Published private(set) var privacyOptionsRequired = false
    /// Units in use, nil until decided.
    @Published private(set) var units: AdUnits?

    /// A loaded interstitial is good for an hour (AdMob); older ones are dropped and loaded again.
    static let interstitialMaxAge: TimeInterval = 55 * 60
    /// After a failed interstitial load, wait this long before the next try.
    static let interstitialRetryDelay: TimeInterval = 120
    private static let historyKey = "adHistory"

    private let monitor = BroadcastMonitor.shared
    private let cast = CastManager.shared
    private let stopAlert = StopAlertCenter.shared
    private var history: AdHistory
    private var started = false
    private var consentUpdated = false
    private var sdkStarting = false
    private var promptedThisLaunch = false
    private var prompting = false
    private var presenting = false
    private var interstitial: InterstitialAd?
    private var interstitialLoadedAt: Date?
    private var interstitialLoading = false
    private var interstitialRetryAt: Date?
    private let presenter = InterstitialPresentation()
    private var subscriptions = Set<AnyCancellable>()
    private var updateScheduled = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode(AdHistory.self, from: data) {
            history = saved
        } else {
            history = AdHistory()
        }
    }

    /// Called once at launch (AppDelegate), after StopAlertCenter.setUp().
    func start() {
        guard !started, DemoMode.current == nil else { return }
        started = true
        Publishers.Merge(monitor.objectWillChange, cast.objectWillChange)
            .sink { [weak self] _ in self?.scheduleUpdate() }
            .store(in: &subscriptions)
        // The notification's "tap to restart" counts as a restart (no interstitial, no prompts).
        stopAlert.$wantsStartCard
            .filter { $0 }
            .sink { [weak self] _ in self?.stopAlertOpened() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleUpdate() }
            .store(in: &subscriptions)
        // "이제 눌러서 시작하세요" is for right after the ad, not for the next visit.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.startPrompt = false }
            .store(in: &subscriptions)
        Task {
            units = await AdStoreEnvironment.units()
            await refreshConsentInfo()
        }
    }

    // MARK: Main screen

    /// The bottom banner is in the view hierarchy (false while sending, over the TV-not-found help,
    /// before consent and in demo mode).
    func showsBanner(troubleshooting: Bool) -> Bool {
        guard adsReady, units != nil, ConsentInformation.shared.canRequestAds else { return false }
        var input = policyInput()
        input.showsTroubleshooting = troubleshooting
        return AdPolicy.showsBanner(input)
    }

    /// The armed start card was tapped: show the ad, then the card is the system picker again.
    func showInterstitial() {
        guard interstitialArmed, !presenting, let ad = interstitial else {
            startPrompt = true
            return
        }
        interstitial = nil
        interstitialLoadedAt = nil
        interstitialArmed = false
        presenting = true
        Task {
            let shown = await presenter.present(ad)
            if shown {
                history.lastInterstitialAt = Date()
                save()
            }
            presenting = false
            startPrompt = true
            update()
        }
    }

    // MARK: 고급·진단

    func presentPrivacyOptions() {
        Task {
            try? await ConsentForm.presentPrivacyOptionsForm(from: nil)
            let consent = ConsentInformation.shared
            privacyOptionsRequired = consent.privacyOptionsRequirementStatus == .required
            if !consent.canRequestAds {
                interstitial = nil
                interstitialLoadedAt = nil
            }
            update()
        }
    }

    // MARK: State

    private func stopAlertOpened() {
        history.stopAlertOpenedAt = Date()
        save()
        scheduleUpdate()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func policyInput(now: Date = Date()) -> AdPolicy.Input {
        var restart = history.stopAlertOpenedAt
        // The extension stopped answering (killed, iPhone locked) or failed: its last update is
        // about when it stopped.
        if monitor.isStale || monitor.status.state == .failed {
            let stoppedAt = monitor.status.updatedAt
            restart = max(restart ?? stoppedAt, stoppedAt)
        }
        return AdPolicy.Input(isSending: monitor.isLive, isDemo: DemoMode.current != nil,
                              showsTroubleshooting: false, broadcastsStarted: history.broadcastsStarted,
                              lastInterstitialAt: history.lastInterstitialAt, restartSignalAt: restart, now: now)
    }

    /// Many changes, one update (the monitor ticks every second, the Cast SDK changes often).
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func update() {
        let now = Date()
        // Every start counts, also one made while the app was away (seen at the next launch).
        if history.registerBroadcast(startedAt: monitor.status.startedAt) { save() }
        let live = monitor.isLive
        if live, startPrompt { startPrompt = false }
        if let at = interstitialLoadedAt, now.timeIntervalSince(at) > Self.interstitialMaxAge {
            interstitial = nil
            interstitialLoadedAt = nil
        }
        let input = policyInput(now: now)
        let armed = adsReady && !presenting && ConsentInformation.shared.canRequestAds
            && AdPolicy.armsInterstitial(input, adLoaded: interstitial != nil)
        if armed != interstitialArmed { interstitialArmed = armed }
        // No SDK start, ad request or prompt while sending or while a TV is connecting.
        guard !live, cast.connection != .connecting else { return }
        startSDKIfAllowed()
        preloadInterstitialIfNeeded(input, now: now)
        promptIfCalm(input)
    }

    // MARK: Consent and tracking

    /// Every launch: refresh the consent status only. The form waits for a calm moment (promptIfCalm).
    private func refreshConsentInfo() async {
        let consent = ConsentInformation.shared
        do {
            try await consent.requestConsentInfoUpdate(with: RequestParameters())
        } catch {
            // Offline or failed: consent from an earlier launch may still allow ads (canRequestAds).
        }
        consentUpdated = true
        privacyOptionsRequired = consent.privacyOptionsRequirementStatus == .required
        update()
    }

    private func promptIfCalm(_ input: AdPolicy.Input) {
        guard consentUpdated, !promptedThisLaunch, !prompting, !presenting,
              UIApplication.shared.applicationState == .active, AdPolicy.asksConsent(input) else { return }
        let consent = ConsentInformation.shared
        let formDue = consent.consentStatus == .required
        let trackingDue = ATTrackingManager.trackingAuthorizationStatus == .notDetermined
        promptedThisLaunch = true
        guard formDue || trackingDue else { return }
        prompting = true
        Task {
            // Google's form first: GDPR consent where required, and the IDFA explainer message (which
            // itself leads to Apple's prompt) when it is published in AdMob.
            if formDue { try? await ConsentForm.loadAndPresentIfRequired(from: nil) }
            privacyOptionsRequired = consent.privacyOptionsRequirementStatus == .required
            // Then Apple's prompt, if Google's form did not already lead to it. No ads, no tracking question.
            if consent.canRequestAds, ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                await requestTrackingWhenActive()
            }
            prompting = false
            update()
        }
    }

    /// iOS shows the tracking prompt only while the app is active; asked a moment too early (a closing
    /// form, the app still inactive) it returns .notDetermined without showing anything. So wait
    /// (bounded) until active, let the closing form finish, ask, and ask once more if nothing was shown.
    private func requestTrackingWhenActive() async {
        for attempt in 0..<2 {
            for _ in 0..<20 where UIApplication.shared.applicationState != .active {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 500 : 1500))
            // A broadcast started meanwhile: no system prompt over the TV picture.
            if monitor.isLive { return }
            if await ATTrackingManager.requestTrackingAuthorization() != .notDetermined { return }
        }
    }

    // MARK: SDK and ads

    private func startSDKIfAllowed() {
        guard consentUpdated, units != nil, !adsReady, !sdkStarting,
              ConsentInformation.shared.canRequestAds else { return }
        sdkStarting = true
        Task {
            _ = await MobileAds.shared.start()
            adsReady = true
            update()
        }
    }

    /// Loads an interstitial only while one could be shown (AdPolicy.interstitialEligible).
    private func preloadInterstitialIfNeeded(_ input: AdPolicy.Input, now: Date) {
        guard adsReady, let units, interstitial == nil, !interstitialLoading, !presenting,
              ConsentInformation.shared.canRequestAds, AdPolicy.interstitialEligible(input) else { return }
        if let retryAt = interstitialRetryAt, now < retryAt { return }
        interstitialLoading = true
        Task {
            let ad = try? await InterstitialAd.load(with: units.interstitial, request: Request())
            interstitial = ad
            interstitialLoadedAt = ad == nil ? nil : Date()
            interstitialRetryAt = ad == nil ? Date().addingTimeInterval(Self.interstitialRetryDelay) : nil
            interstitialLoading = false
            update()
        }
    }
}

/// Presents an interstitial and resumes once it is closed (or could not be shown), with whether it
/// was on screen. Holds the ad until then: the SDK keeps only a weak delegate.
private final class InterstitialPresentation: NSObject, FullScreenContentDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var showing: InterstitialAd?
    private var presented = false

    @MainActor
    func present(_ ad: InterstitialAd) async -> Bool {
        // One at a time, and never a present call the SDK already knows will fail (expired, no window):
        // that would leave the start card waiting for a callback.
        guard continuation == nil else { return false }
        do {
            try ad.canPresent(from: nil)
        } catch {
            return false
        }
        return await withCheckedContinuation { cont in
            continuation = cont
            showing = ad
            presented = false
            ad.fullScreenContentDelegate = self
            ad.present(from: nil)
        }
    }

    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        presented = true
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        finish(true)
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        finish(presented)
    }

    private func finish(_ shown: Bool) {
        let cont = continuation
        continuation = nil
        showing = nil
        cont?.resume(returning: shown)
    }
}

/// Anchored adaptive banner (Google's size for the width, so the ad is never cropped).
struct AdBanner: UIViewRepresentable {
    let width: CGFloat
    let unitID: String

    /// The banner's size for this width; the same size makeUIView asks for.
    @MainActor static func size(width: CGFloat) -> CGSize { largeAnchoredAdaptiveBanner(width: width).size }

    func makeUIView(context: Context) -> BannerView {
        let view = BannerView(adSize: largeAnchoredAdaptiveBanner(width: width))
        view.adUnitID = unitID
        view.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
        view.load(Request())
        return view
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}

/// Slot at the bottom of the main screen, exactly the banner's size, kept apart from the buttons
/// above it (a gap and a divider; AdMob's accidental-click guidance). Removed while sending.
struct AdBannerSlot: View {
    let unitID: String
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            // Measures the available width; the banner is made once it is known.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if width > 0 {
                let size = AdBanner.size(width: width)
                AdBanner(width: width, unitID: unitID)
                    .frame(width: size.width, height: size.height)
                    // Portrait only, so the width should not change; if it does, a new banner fits it.
                    .id(width)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// "광고 신고" (2.5.18): a mail to the user-facing support address with the subject filled in.
enum AdReport {
    static var mailURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = DiagnosticsReport.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: String(localized: "MirrorDrop 광고 신고")),
            URLQueryItem(name: "body", value: String(localized: "어떤 광고였나요? (광고 내용, 본 시각, 가능하면 화면 캡처)\n\n앱 버전: \(AppLinks.versionText)")),
        ]
        return components.url ?? URL(string: "mailto:\(DiagnosticsReport.supportEmail)")!
    }
}
