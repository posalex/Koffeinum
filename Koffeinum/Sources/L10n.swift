import Foundation

/// Typed, centralised access to all user-facing strings.
///
/// Uses `NSLocalizedString` (not `String(localized:)`) for macOS 12 compatibility.
/// Lookup order follows the system: the user's preferred language if a matching
/// `.lproj` is bundled, otherwise `CFBundleDevelopmentRegion` (English).
enum L10n {

    // MARK: - App

    /// Always "Koffeinum" — intentionally not localised.
    static let appName = "Koffeinum"

    static var appTooltip: String      { s("app.tooltip") }
    static var statusInactiveA11y: String { s("a11y.status.inactive") }
    static func statusActiveA11y(_ time: String) -> String { f("a11y.status.active", time) }

    // MARK: - Durations (menu titles)

    static var duration15min: String   { s("duration.15min") }
    static var duration30min: String   { s("duration.30min") }
    static var duration1h: String      { s("duration.1h") }
    static var duration2h: String      { s("duration.2h") }
    static var duration3h: String      { s("duration.3h") }
    static var duration4h: String      { s("duration.4h") }
    static var duration5h: String      { s("duration.5h") }
    static var durationIndefinite: String { s("duration.indefinite") }

    // MARK: - Menu

    static var menuStop: String        { s("menu.stop") }
    static func menuStopWithTime(_ time: String) -> String { f("menu.stop.with_time", time) }
    static var menuStopIndefinite: String { s("menu.stop.indefinite") }
    static var menuLaunchAtLogin: String { s("menu.launch_at_login") }
    static var menuQuit: String        { s("menu.quit") }
    static func menuActiveHeader(_ modeShortLabel: String) -> String {
        f("menu.active_header", modeShortLabel)
    }
    static func menuErrorPrefix(_ error: String) -> String { f("menu.error_prefix", error) }

    // MARK: - Mode labels (alternates + header)

    static var modeDefaultShort: String    { s("mode.default.short") }
    static var modeIdleOnlyShort: String   { s("mode.idle_only.short") }
    static var modeDiskSleepShort: String  { s("mode.disk_sleep.short") }
    static var modeSystemSleepShort: String { s("mode.system_sleep.short") }

    /// Used when appending a modifier hint to a duration's alternate title,
    /// e.g. "15 Minuten  ⌥ Nur Idle-Schlaf".
    static func alternateTitle(base: String, modifier: String) -> String {
        String(format: s("menu.alternate_title"), base, modifier)
    }

    // MARK: - Mode descriptions (long, for possible future UI)

    static var modeDefaultDescription: String    { s("mode.default.description") }
    static var modeIdleOnlyDescription: String   { s("mode.idle_only.description") }
    static var modeDiskSleepDescription: String  { s("mode.disk_sleep.description") }
    static var modeSystemSleepDescription: String { s("mode.system_sleep.description") }

    // MARK: - Modifier tooltips

    static var tooltipOption: String   { s("tooltip.option") }
    static var tooltipControl: String  { s("tooltip.control") }
    static var tooltipShift: String    { s("tooltip.shift") }

    // MARK: - Launch-at-Login

    static var launchAtLoginRequiresVentura: String { s("launch_at_login.requires_ventura") }
    static var launchAtLoginFailedTitle: String     { s("launch_at_login.failed_title") }

    // MARK: - Notifications

    static var notificationTimerEndedBody: String { s("notification.timer_ended.body") }

    // MARK: - Errors

    static func caffeinateStartFailed(_ message: String) -> String {
        f("error.caffeinate_start_failed", message)
    }

    // MARK: - Internals

    private static func s(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private static func f(_ key: String, _ arg: CVarArg) -> String {
        String(format: NSLocalizedString(key, comment: ""), arg)
    }
}
