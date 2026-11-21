import Foundation
import StoreKit

/// Which ad units this run uses (AdUnits.choose in Shared/AdPolicy.swift). Kept apart from
/// AdsManager.swift so StoreKit's names never meet Google Mobile Ads' names in one file.
///
/// TestFlight and App Review builds are the same Release binary as the App Store one, so a build
/// setting cannot tell them apart. StoreKit's app transaction can: `.production` only for an App
/// Store download; TestFlight and App Review are `.sandbox`. Anything unsure (error, no answer within
/// a few seconds) means Google's test ads: losing a little revenue is safer than the owner tapping a
/// live ad, which AdMob treats as invalid traffic (the AdMob account is shared with other apps).
enum AdStoreEnvironment {
    /// The live IDs from Info.plist (build settings ADMOB_BANNER / ADMOB_INTERSTITIAL, ios/project.yml).
    static var configured: AdUnits {
        func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }
        return AdUnits(banner: info("MDAdMobBanner"), interstitial: info("MDAdMobInterstitial"))
    }

    static var isTestBuild: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func units() async -> AdUnits {
        if isTestBuild { return .test }
        return AdUnits.choose(configured: configured, isTestBuild: false, store: await store())
    }

    /// StoreKit's answer, or `.unknown` after `timeout` seconds.
    private static func store(timeout: TimeInterval = 5) async -> AdUnits.Store {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task.detached { once.resume(await lookup()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(.unknown)
            }
        }
    }

    private static func lookup() async -> AdUnits.Store {
        guard case .verified(let transaction) = try? await AppTransaction.shared else { return .unknown }
        switch transaction.environment {
        case .production: return .appStore
        case .sandbox, .xcode: return .sandbox
        default: return .unknown
        }
    }
}

/// Resumes a continuation with the first answer only (StoreKit or the timeout, whichever is first).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AdUnits.Store, Never>?

    init(_ continuation: CheckedContinuation<AdUnits.Store, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: AdUnits.Store) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
