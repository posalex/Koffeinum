import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Strong singleton — `NSApplication.delegate` is weak, so something has to
    /// keep the instance alive for the lifetime of the process.
    static let shared = AppDelegate()

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()

        // Ask for notification permission upfront so the timer-ended banner can
        // fire later without a permission prompt appearing at t=0.
        // Silently ignored for unsigned local builds — the notification center
        // requires a properly signed bundle to grant authorization.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in /* no-op */ }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaffeinateManager.shared.stop()
    }
}
