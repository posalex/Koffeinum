import Foundation
import UserNotifications

@MainActor
protocol CaffeinateManagerDelegate: AnyObject {
    /// Called any time observable state on the manager changes
    /// (`isActive`, `remainingSeconds`, `isIndefinite`, `currentMode`, `lastError`).
    func caffeinateManagerDidChange(_ manager: CaffeinateManager)
}

/// Manages the `caffeinate` child process and the countdown timer.
///
/// Uses a plain delegate instead of Combine/`ObservableObject` — a single
/// observer (the status-bar controller) is all we need and it saves loading the
/// Combine runtime.
///
/// All mutable state is touched only from the main thread (menu actions + a
/// main-runloop timer), so the class is `@MainActor` to make that invariant
/// explicit and compiler-enforced.
@MainActor
final class CaffeinateManager {
    static let shared = CaffeinateManager()

    weak var delegate: CaffeinateManagerDelegate?

    private(set) var isActive = false
    private(set) var remainingSeconds: Int = 0
    /// `true` means the user chose "run until I say stop" — no countdown.
    private(set) var isIndefinite = false
    /// The mode currently being enforced; `nil` when inactive.
    private(set) var currentMode: Mode?
    /// Populated when the last `start()` failed; cleared on the next `start()`.
    private(set) var lastError: String?

    private var process: Process?
    private var timer: Timer?
    private var endDate: Date?

    private init() {}

    // MARK: - Caffeinate Modes

    enum Mode: CustomStringConvertible, CaseIterable {
        /// Default: prevent display and system sleep (-d -i)
        case displayAndIdle
        /// Option/Alt: prevent system idle sleep only (-i)
        case idleOnly
        /// Ctrl: prevent disk sleep (-m)
        case diskSleep
        /// Shift: prevent system sleep (-s)
        case systemSleep

        var arguments: [String] {
            switch self {
            case .displayAndIdle: return ["-d", "-i"]
            case .idleOnly:      return ["-i"]
            case .diskSleep:     return ["-m"]
            case .systemSleep:   return ["-s"]
            }
        }

        /// Full, human-readable description of the mode (shown in tooltips).
        var description: String {
            switch self {
            case .displayAndIdle: return L10n.modeDefaultDescription
            case .idleOnly:      return L10n.modeIdleOnlyDescription
            case .diskSleep:     return L10n.modeDiskSleepDescription
            case .systemSleep:   return L10n.modeSystemSleepDescription
            }
        }

        /// Short label used in menu alternates and in the "Aktiv: ..." header.
        var shortLabel: String {
            switch self {
            case .displayAndIdle: return L10n.modeDefaultShort
            case .idleOnly:      return L10n.modeIdleOnlyShort
            case .diskSleep:     return L10n.modeDiskSleepShort
            case .systemSleep:   return L10n.modeSystemSleepShort
            }
        }
    }

    // MARK: - Public API

    /// Start `caffeinate` for a bounded number of seconds.
    /// Pass `nil` to run indefinitely until `stop()` is called.
    func start(seconds: Int?, mode: Mode = .displayAndIdle) {
        stop()
        lastError = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

        var args = mode.arguments
        if let seconds, seconds > 0 {
            args += ["-t", "\(seconds)"]
        }
        // `-w <pid>`: caffeinate exits automatically when we (the parent) die.
        // Belt-and-braces guard in case the child survives a force-kill of the
        // parent before `applicationWillTerminate` can fire.
        args += ["-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        proc.arguments = args

        do {
            try proc.run()
        } catch {
            let message = L10n.caffeinateStartFailed(error.localizedDescription)
            lastError = message
            NSLog("%@", message)
            notifyChanged()
            return
        }

        process = proc
        currentMode = mode

        if let seconds, seconds > 0 {
            endDate = Date().addingTimeInterval(TimeInterval(seconds))
            remainingSeconds = seconds
            isIndefinite = false
        } else {
            endDate = nil
            remainingSeconds = 0
            isIndefinite = true
        }
        isActive = true

        // `scheduledTimer` installs the timer on the main runloop's `.default`
        // mode. We *additionally* register it on `.common` so it keeps firing
        // while tracking runloops are active (e.g. while a menu is open).
        //
        // The timer fires on the main thread but its closure isn't typed
        // `@MainActor`; `MainActor.assumeIsolated` lets us call main-isolated
        // state synchronously without strict-concurrency warnings.
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        notifyChanged()
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        let wasActive = isActive

        process = nil
        endDate = nil
        remainingSeconds = 0
        isIndefinite = false
        isActive = false
        currentMode = nil

        if wasActive { notifyChanged() }
    }

    // MARK: - Formatted Time

    var formattedTime: String {
        if isIndefinite { return "∞" }
        let h = remainingSeconds / 3600
        let m = (remainingSeconds % 3600) / 60
        let s = remainingSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - Private

    private func tick() {
        // Indefinite runs don't count down.
        if isIndefinite { return }

        guard let end = endDate else {
            stop()
            return
        }

        // Round instead of truncate so the first visible second doesn't flicker.
        let remaining = Int(end.timeIntervalSinceNow.rounded())
        if remaining <= 0 {
            stop()
            postTimerEndedNotification()
        } else {
            remainingSeconds = remaining
            notifyChanged()
        }
    }

    private func notifyChanged() {
        delegate?.caffeinateManagerDidChange(self)
    }

    private func postTimerEndedNotification() {
        let center = UNUserNotificationCenter.current()
        let title = L10n.appName
        let body  = L10n.notificationTimerEndedBody
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "koffeinum.timer.ended",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
