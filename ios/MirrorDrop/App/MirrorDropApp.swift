import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The Cast context must exist before any Cast UI is created.
        CastManager.shared.setUp()
        return true
    }
}

@main
struct MirrorDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var cast = CastManager.shared
    @StateObject private var monitor = BroadcastMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cast)
                .environmentObject(monitor)
        }
    }
}
