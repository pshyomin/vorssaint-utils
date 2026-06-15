import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusController: StatusItemController!
    private let popover = NSPopover()
    private var popoverClosedAt = Date.distantPast
    private var popoverDismissMonitor: Any?
    private var isTerminating = false
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Finish the on-disk rename for installs carried over from a pre-2.5
        // build, or retire a leftover old-named bundle. Returns true when we are
        // quitting to relaunch under the new name, so skip the rest of startup.
        if BundleMigration.run() { return }

        statusController = StatusItemController()
        statusController.onLeftClick = { [weak self] in self?.togglePopover() }
        statusController.onRightClick = { [weak self] in self?.showContextMenu() }

        setUpPopover()
        bindManagers()

        HotkeyManager.shared.onActivate = { KeepAwakeManager.shared.toggle() }
        HotkeyManager.shared.setEnabled(UserDefaults.standard.bool(forKey: DefaultsKey.hotkeyEnabled))

        KeepAwakeManager.shared.recoverIfNeeded()
        AppActivationTracker.shared.start()
        ScrollInverter.shared.syncWithPreferences()
        AppSwitcher.shared.syncWithPreferences()
        FinderCutPaste.shared.syncWithPreferences()
        AutoQuitService.shared.syncWithPreferences()
        ShelfService.shared.syncWithPreferences()
        AppVolumeMixer.shared.start()
        UpdateService.shared.startAutomaticChecks()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)

        // If Accessibility is granted while the app is running (e.g. during
        // onboarding), bring the input features up without a relaunch.
        Permissions.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                ScrollInverter.shared.syncWithPreferences()
                AppSwitcher.shared.syncWithPreferences()
                FinderCutPaste.shared.syncWithPreferences()
                AutoQuitService.shared.syncWithPreferences()
            }
            .store(in: &cancellables)

        if !UserDefaults.standard.bool(forKey: DefaultsKey.hasOnboarded) {
            showOnboarding(mode: .full)
        } else if UserDefaults.standard.integer(forKey: DefaultsKey.featuresOnboardingVersion) < OnboardingInfo.currentFeatureSet {
            // Existing users see a short tour once, to discover and configure
            // this version's new features.
            showOnboarding(mode: .whatsNew)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        AppVolumeMixer.shared.stopAll()
        KeepAwakeManager.shared.deactivate(reason: .quit)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func bindManagers() {
        KeepAwakeManager.shared.onSessionEnded = { reason in
            let strings = L10n.shared.s
            switch reason {
            case .timer:
                Notifier.post(title: strings.notifySessionEndedTitle, body: strings.notifySessionEndedBody)
            case .battery:
                Notifier.post(title: strings.notifyBatteryTitle, body: strings.notifyBatteryBody)
            default:
                break
            }
        }
    }

    // MARK: - Main panel

    private func setUpPopover() {
        // Application-defined (not .transient) so the panel stays open while the
        // user works in our own Settings window and sees changes live. A global
        // click monitor + resign-active still dismiss it for clicks in other apps.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: MenuPanelView())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // The click that just transient-dismissed the popover also lands here;
        // reopening would make the panel look impossible to close.
        guard Date().timeIntervalSince(popoverClosedAt) > 0.35 else { return }
        guard let button = statusController.button else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            // Keep the panel alive next to fullscreen apps and on any Space —
            // without this it blinks shut when another display is fullscreen.
            window.collectionBehavior.insert([.fullScreenAuxiliary, .canJoinAllSpaces])
            window.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
        // Only arm the dismiss monitor if the popover actually presented — otherwise
        // popoverDidClose never fires and the global monitor would leak indefinitely.
        guard popover.isShown else { return }
        installPopoverDismissMonitor()
    }

    private func installPopoverDismissMonitor() {
        removePopoverDismissMonitor()
        // A global monitor only sees events delivered to OTHER apps, so a click in
        // another app or on the desktop dismisses the panel — while clicks in our
        // own Settings window do not, so the two can be used side by side.
        popoverDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }
    }

    private func removePopoverDismissMonitor() {
        if let monitor = popoverDismissMonitor {
            NSEvent.removeMonitor(monitor)
            popoverDismissMonitor = nil
        }
    }

    @objc private func appResignedActive() {
        // Leaving the app entirely (e.g. ⌘Tab) dismisses the panel; switching to
        // our own Settings window keeps the app active, so it stays open.
        if popover.isShown { closePopover() }
    }

    @objc private func appBecameActive() {
        // Coming back to the app is a good moment to surface a fresh release.
        UpdateService.shared.checkIfStale()
    }

    func closePopover(after delay: TimeInterval = 0) {
        if delay <= 0 {
            popover.performClose(nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.popover.performClose(nil)
            }
        }
    }

    // While the panel is on screen the monitor samples everything (temperatures,
    // GPU, graphs); when it closes it keeps going only if a menu bar metric needs it.
    func popoverWillShow(_ notification: Notification) {
        SystemMonitor.shared.panelDidAppear()
        UpdateService.shared.checkIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        SystemMonitor.shared.panelDidDisappear()
        removePopoverDismissMonitor()
        popoverClosedAt = Date()
    }

    // MARK: - Context menu (right click)

    private func showContextMenu() {
        let manager = KeepAwakeManager.shared
        let strings = L10n.shared.s
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: manager.isActive ? strings.menuDisableAwake : strings.menuEnableAwake,
                                    action: #selector(menuToggleAwake),
                                    keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        if !manager.isActive {
            let durationsItem = NSMenuItem(title: strings.menuActivateFor, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let options: [(String, Int)] = [(strings.minutes15, 15), (strings.minutes30, 30),
                                            (strings.hour1, 60), (strings.hours2, 120),
                                            (strings.hours4, 240), (strings.hours8, 480),
                                            (strings.indefinitely, 0)]
            for (label, minutes) in options {
                let item = NSMenuItem(title: label, action: #selector(menuActivateDuration(_:)), keyEquivalent: "")
                item.target = self
                item.tag = minutes
                submenu.addItem(item)
            }
            durationsItem.submenu = submenu
            menu.addItem(durationsItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: strings.menuSettings, action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: strings.menuAbout, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let uninstallItem = NSMenuItem(title: strings.uninstallerMenuItem,
                                       action: #selector(menuOpenUninstaller), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        if UserDefaults.standard.bool(forKey: DefaultsKey.shelfEnabled) {
            let shelfItem = NSMenuItem(title: strings.shelfMenuItem,
                                       action: #selector(menuOpenShelf), keyEquivalent: "")
            shelfItem.target = self
            menu.addItem(shelfItem)
        }

        let updatesItem = NSMenuItem(title: strings.menuCheckUpdates, action: #selector(menuCheckUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: strings.menuQuit, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusController.statusItem.menu = menu
        statusController.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusController.statusItem.menu = nil
        }
    }

    @objc private func menuToggleAwake() {
        KeepAwakeManager.shared.toggle()
    }

    @objc private func menuActivateDuration(_ sender: NSMenuItem) {
        KeepAwakeManager.shared.activate(minutes: sender.tag)
    }

    @objc private func menuOpenSettings() {
        openSettingsWindow()
    }

    @objc private func menuOpenUninstaller() {
        SettingsRouter.shared.page = .uninstaller
        openSettingsWindow()
    }

    @objc private func menuOpenShelf() {
        ShelfService.shared.summon()
    }

    @objc private func menuCheckUpdates() {
        UpdateService.shared.check(manual: true)
        openSettingsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: L10n.shared.s.aboutDescription,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - Windows

    func openSettingsWindow() {
        // Intentionally does NOT close the panel: the panel uses applicationDefined
        // dismissal, so it stays open beside Settings for a live preview.
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = L10n.shared.s.settingsTitle
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Quits and reopens the app. Full Disk Access only applies to a fresh
    /// process, so this is how the uninstaller picks up a just-granted grant.
    func relaunchApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.3; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    func showOnboarding(mode: OnboardingMode = .full) {
        closePopover()
        if let window = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: OnboardingView(mode: mode) { [weak self] in
            self?.markOnboardingComplete()
            Notifier.requestPermission()
            self?.onboardingWindow?.close()
        })
        let window = NSWindow(contentViewController: host)
        window.title = mode == .whatsNew ? L10n.shared.s.obWhatsNewTitle : L10n.shared.s.obStepWelcomeTitle
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        onboardingWindow = nil
        // Closing the window mid-flow counts as "skip" — but quitting (e.g.
        // the relaunch macOS forces after granting Screen Recording) must NOT,
        // so the flow can resume where it stopped.
        guard !isTerminating else { return }
        markOnboardingComplete()
    }

    /// Marks both the first run and this version's feature tour as seen, so
    /// neither reappears on the next launch.
    private func markOnboardingComplete() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.hasOnboarded)
        UserDefaults.standard.set(OnboardingInfo.currentFeatureSet, forKey: DefaultsKey.featuresOnboardingVersion)
    }
}
