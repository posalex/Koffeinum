import AppKit
import ServiceManagement

@MainActor
final class StatusBarController: NSObject, CaffeinateManagerDelegate {

    // Tag values used by `menuWillOpen` to find control items. Kept well below
    // any real duration-in-seconds tag (and below the indefinite sentinel -1)
    // to avoid collisions.
    private enum Tag {
        static let stop       = -1000
        static let modeHeader = -1001
        static let errorItem  = -1002
    }

    /// Sentinel `tag` value meaning "run indefinitely".
    private static let indefiniteSeconds = -1

    private let statusItem: NSStatusItem
    private let caffeinateManager = CaffeinateManager.shared
    private var menu: NSMenu!
    private var launchAtLoginItem: NSMenuItem!

    // Tooltip window is cached and reused instead of rebuilt on every flag change.
    private var tooltipWindow: NSWindow?
    private var tooltipLabel: NSTextField?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var menuIsOpen = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.setAccessibilityLabel(L10n.appName)
        statusItem.button?.toolTip = L10n.appTooltip
        updateIcon()
        buildMenu()
        statusItem.menu = menu

        // Subscribe via delegate (no Combine — no Combine runtime loaded).
        caffeinateManager.delegate = self

        // Monitor modifier key changes for the tooltip — both local (menu open
        // / app key) and global (so the hint appears before the user clicks).
        setupModifierKeyMonitoring()
    }

    // MARK: - CaffeinateManagerDelegate

    func caffeinateManagerDidChange(_ manager: CaffeinateManager) {
        updateIcon()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        if caffeinateManager.isActive {
            let time = caffeinateManager.formattedTime
            let text = "\(time) 👀"

            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.orange,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ]
            let attributed = NSMutableAttributedString(string: text, attributes: attributes)

            // Eyes emoji without orange color so it keeps its native rendering.
            let eyesRange = (text as NSString).range(of: "👀")
            if eyesRange.location != NSNotFound {
                attributed.removeAttribute(.foregroundColor, range: eyesRange)
            }

            button.attributedTitle = attributed
            button.image = nil
            button.setAccessibilityLabel(L10n.statusActiveA11y(time))
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = "☕👀"
            button.setAccessibilityLabel(L10n.statusInactiveA11y)
        }
    }

    // MARK: - Menu

    private func durationItems() -> [(String, Int)] {
        return [
            (L10n.duration15min, 15 * 60),
            (L10n.duration30min, 30 * 60),
            (L10n.duration1h,    1 * 3600),
            (L10n.duration2h,    2 * 3600),
            (L10n.duration3h,    3 * 3600),
            (L10n.duration4h,    4 * 3600),
            (L10n.duration5h,    5 * 3600),
        ]
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Mode header — visible only while active.
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.tag = Tag.modeHeader
        header.isEnabled = false
        header.isHidden = true
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Error item — shown only when the last start() failed.
        let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.tag = Tag.errorItem
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(errorItem)

        // Fixed durations + three alternates each (⌥/⌃/⇧). Alternates share a
        // visual slot with the primary item; AppKit swaps them based on the
        // currently held modifier. This is the documented pattern and strictly
        // more robust than inspecting NSApp.currentEvent on click.
        for (title, seconds) in durationItems() {
            addDurationItem(title: title, seconds: seconds)
        }

        // "Keep awake indefinitely" — caffeinate without `-t`.
        menu.addItem(NSMenuItem.separator())
        addDurationItem(title: L10n.durationIndefinite, seconds: Self.indefiniteSeconds)

        // Stop item (only shown when active)
        menu.addItem(NSMenuItem.separator())
        let stopItem = NSMenuItem(title: L10n.menuStop, action: #selector(stopCaffeinate), keyEquivalent: "")
        stopItem.target = self
        stopItem.tag = Tag.stop
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        launchAtLoginItem = NSMenuItem(title: L10n.menuLaunchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        if #available(macOS 13.0, *) {
            // State is driven from SMAppService.status.
        } else {
            // On macOS 12 we have no in-process API to manage this without a
            // separate LoginItem helper target — disable with a tooltip rather
            // than silently failing.
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.toolTip = L10n.launchAtLoginRequiresVentura
        }
        updateLaunchAtLoginState()
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Adds one primary `NSMenuItem` plus three alternates (⌥/⌃/⇧) for the given duration.
    ///
    /// Shift is used for "system sleep" instead of Cmd because AppKit's menu
    /// system treats Cmd specially for key equivalents and doesn't reliably
    /// swap alternates when only Cmd is held.
    private func addDurationItem(title: String, seconds: Int) {
        let primary = NSMenuItem(title: title, action: #selector(timeSelected(_:)), keyEquivalent: "")
        primary.target = self
        primary.tag = seconds
        primary.representedObject = CaffeinateManager.Mode.displayAndIdle
        menu.addItem(primary)

        let alternates: [(NSEvent.ModifierFlags, CaffeinateManager.Mode, String)] = [
            (.option,  .idleOnly,    L10n.modeIdleOnlyShort),
            (.control, .diskSleep,   L10n.modeDiskSleepShort),
            (.shift,   .systemSleep, L10n.modeSystemSleepShort),
        ]

        for (mask, mode, modifierLabel) in alternates {
            let alt = NSMenuItem(
                title: L10n.alternateTitle(base: title, modifier: modifierLabel),
                action: #selector(timeSelected(_:)),
                keyEquivalent: ""
            )
            alt.target = self
            alt.tag = seconds
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = mask
            alt.representedObject = mode
            menu.addItem(alt)
        }
    }

    // MARK: - Actions

    @objc private func timeSelected(_ sender: NSMenuItem) {
        let seconds = sender.tag
        let mode = (sender.representedObject as? CaffeinateManager.Mode) ?? .displayAndIdle

        if seconds == Self.indefiniteSeconds {
            caffeinateManager.start(seconds: nil, mode: mode)
        } else {
            caffeinateManager.start(seconds: seconds, mode: mode)
        }
    }

    @objc private func stopCaffeinate() {
        caffeinateManager.stop()
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            let currentlyEnabled = (service.status == .enabled)
            do {
                if currentlyEnabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                NSLog("Failed to toggle launch at login: %@", String(describing: error))
                presentError(
                    title: L10n.launchAtLoginFailedTitle,
                    message: error.localizedDescription
                )
            }
            updateLaunchAtLoginState()
        }
        // On macOS 12 the menu item is disabled, so this can't fire.
    }

    private func updateLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            let enabled = (SMAppService.mainApp.status == .enabled)
            launchAtLoginItem.state = enabled ? .on : .off
        } else {
            launchAtLoginItem.state = .off
        }
    }

    @objc private func quit() {
        CaffeinateManager.shared.stop()
        NSApp.terminate(nil)
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Modifier Key Tooltip

    private func setupModifierKeyMonitoring() {
        // AppKit delivers these callbacks on the main thread, but the closure
        // types themselves are not annotated `@MainActor`. Bouncing through
        // `MainActor.assumeIsolated` avoids strict-concurrency warnings while
        // remaining synchronous.

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handleModifierChange(flags) }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handleModifierChange(flags) }
        }
    }

    private func handleModifierChange(_ flags: NSEvent.ModifierFlags) {
        guard menuIsOpen else {
            hideTooltip()
            return
        }

        let tooltipText: String?
        if flags.contains(.option) {
            tooltipText = L10n.tooltipOption
        } else if flags.contains(.control) {
            tooltipText = L10n.tooltipControl
        } else if flags.contains(.shift) {
            tooltipText = L10n.tooltipShift
        } else {
            tooltipText = nil
        }

        if let text = tooltipText {
            // Suppress the native status-bar tooltip while the modifier hint is
            // visible — otherwise the two tooltips overlap (e.g. "Koffeinum —
            // Schlaf verhindern" stacked on top of the modifier description).
            // `removeAllToolTips()` forces AppKit to dismiss any already-visible
            // tooltip window immediately; setting `toolTip = nil` alone only
            // prevents *new* tooltips.
            if let button = statusItem.button {
                button.removeAllToolTips()
                button.toolTip = nil
            }
            showTooltip(text)
        } else {
            // Restore the native tooltip once no modifier is held.
            statusItem.button?.toolTip = L10n.appTooltip
            hideTooltip()
        }
    }

    private func showTooltip(_ text: String) {
        let window = tooltipWindow ?? makeTooltipWindow()
        tooltipWindow = window

        let label: NSTextField
        if let existing = tooltipLabel {
            label = existing
            label.stringValue = text
        } else {
            label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            window.contentView?.addSubview(label)
            tooltipLabel = label
        }
        label.sizeToFit()

        let padding: CGFloat = 8
        let size = NSSize(
            width:  label.frame.width  + padding * 2,
            height: label.frame.height + padding * 2
        )
        label.frame.origin = NSPoint(x: padding, y: padding)

        // Clamp to the screen containing the cursor.
        let mouse = NSEvent.mouseLocation
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 4)
        origin.x = min(max(screenFrame.minX, origin.x), screenFrame.maxX - size.width)
        origin.y = min(max(screenFrame.minY, origin.y), screenFrame.maxY - size.height)

        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFront(nil)
    }

    private func makeTooltipWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        window.level = .floating
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 6
        return window
    }

    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
    }

    deinit {
        if let m = localEventMonitor  { NSEvent.removeMonitor(m) }
        if let m = globalEventMonitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - NSMenuDelegate

extension StatusBarController: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        hideTooltip()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateLaunchAtLoginState()

        let isActive = caffeinateManager.isActive

        if let header = menu.items.first(where: { $0.tag == Tag.modeHeader }) {
            if isActive, let mode = caffeinateManager.currentMode {
                header.title = L10n.menuActiveHeader(mode.shortLabel)
                header.isHidden = false
            } else {
                header.isHidden = true
            }
        }

        if let errItem = menu.items.first(where: { $0.tag == Tag.errorItem }) {
            if let err = caffeinateManager.lastError {
                errItem.title = L10n.menuErrorPrefix(err)
                errItem.isHidden = false
            } else {
                errItem.isHidden = true
            }
        }

        if let stopItem = menu.items.first(where: { $0.tag == Tag.stop }) {
            stopItem.isHidden = !isActive
            if isActive {
                stopItem.title = caffeinateManager.isIndefinite
                    ? L10n.menuStopIndefinite
                    : L10n.menuStopWithTime(caffeinateManager.formattedTime)
            }
        }
    }
}
