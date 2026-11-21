import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The Cast context must exist before any Cast UI is created.
        CastManager.shared.setUp()
        #if MD_DEMO
        // Store screenshots (App/DemoMode.swift): fake TV, and no real play requests.
        if let demo = DemoMode.current {
            CastManager.shared.applyDemo(demo)
        } else {
            MirrorCastCoordinator.shared.start()
        }
        #else
        // Sends the mirror when ready, also while the app is in the background.
        MirrorCastCoordinator.shared.start()
        #endif
        AudioOutput.removeLegacySettings()
        // Notification delegate before launch finishes, so a tap that launched the app is handled.
        StopAlertCenter.shared.setUp()
        // Ads (App/AdsManager.swift): only refreshes the consent status now; the SDK, ad requests and the
        // consent / tracking prompts follow the rules there. Does nothing in demo mode.
        AdsManager.shared.start()
        return true
    }
}

@main
struct MirrorDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var cast = CastManager.shared
    @StateObject private var monitor = BroadcastMonitor.shared
    @StateObject private var stopAlert = StopAlertCenter.shared
    @StateObject private var ads = AdsManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cast)
                .environmentObject(monitor)
                .environmentObject(stopAlert)
                .environmentObject(ads)
        }
    }
}
