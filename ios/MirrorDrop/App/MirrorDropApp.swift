import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The Cast context must exist before any Cast UI is created.
        CastManager.shared.setUp()
        // Sends the mirror when ready, also while the app is in the background.
        MirrorCastCoordinator.shared.start()
        AudioOutput.removeLegacySettings()
        // Notification delegate before launch finishes, so a tap that launched the app is handled.
        StopAlertCenter.shared.setUp()
        return true
    }
}

@main
struct MirrorDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var cast = CastManager.shared
    @StateObject private var monitor = BroadcastMonitor.shared
    @StateObject private var stopAlert = StopAlertCenter.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cast)
                .environmentObject(monitor)
                .environmentObject(stopAlert)
        }
    }
}
