import SwiftUI
#if os(iOS)
import UIKit
import UserNotifications
#endif

@main
enum SwiptMain {
    static func main() {
        #if os(macOS)
        // AppKit opens no default window whenever saved state exists, even if SwiftUI restores no window from it,
        // unless the app is already active (AppKit 2775.10.103.1, macOS 27.0.1 26A434,
        // UUID 2688AFBC-5C39-3132-BCF5-8D00D32D7615,
        // -[NSApplication _reopenWindowsAsNecessaryIncludingRestorableState:withFullFidelity:completionHandler:]
        // 0x1852a5f00..0x1852a5ff4,
        // -[NSPersistentUIRestorer _finishedRestoringWindowsWith_ZOrder:options:completionHandler:] 0x185ca0144..0x185ca01d0,
        // ___58-[NSApplication(NSAppleEventHandling) _handleAEOpenEvent:]_block_invoke 0x185024488..0x1850244c0).
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        #endif
        SwiptApp.main()
    }
}

final class AppLaunch {
    init() {
        _ = AppDatabase.shared
        #if os(iOS)
        BadgeDots.install()
        if Platform.isSupported {
            Platform.shared.start()
        }
        #endif
    }
}

struct SwiptApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    private let launch = AppLaunch()

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            HomeView()
        }
        #else
        Window(Text(verbatim: "Swipt"), id: "home") {
            HomeView()
        }
        .defaultSize(width: 900, height: 560)
        .commands {
            AppCommands()
            SidebarCommands()
        }
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if content.categoryIdentifier == ErrorAlert.notificationCategory {
            ErrorAlert.shared.reopen(content)
        }
    }
}
#endif
