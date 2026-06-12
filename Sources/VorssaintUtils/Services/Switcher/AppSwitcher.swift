import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// The window switcher: a global event tap takes over ⌘Tab, and while ⌘ is held
/// a non-activating panel cycles through real windows — release commits, Q quits
/// the highlighted app, Esc cancels. The panel joins every Space and fullscreen
/// app, so the switcher is available wherever the user is.
final class AppSwitcher: ObservableObject {
    static let shared = AppSwitcher()

    @Published private(set) var windows: [SwitcherItem] = []
    @Published private(set) var previews: [CGWindowID: CGImage] = [:]
    @Published private(set) var selectedIndex = 0
    @Published private(set) var grid = SwitcherGrid.empty

    private var sessionActive = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var panel: NSPanel?

    /// The panel appears only after this delay, like the system switcher: a
    /// quick ⌘Tab flick switches with no UI at all, which is what makes rapid
    /// toggling feel instant instead of flashing a window.
    private static let appearanceDelay: TimeInterval = 0.1
    private var pendingShow: DispatchWorkItem?
    /// True once the user moved the selection themselves — after that, async
    /// tab merges must keep their choice instead of recomputing the default.
    private var userNavigated = false
    /// Mouse position when the panel appeared; hover is inert until it moves.
    private var hoverAnchor: NSPoint?

    // The switcher always takes over ⌘Tab to replace the system switcher.
    private let modifierFlag = CGEventFlags.maskCommand
    private let conflictingFlag = CGEventFlags.maskAlternate

    // Virtual key codes handled during a session.
    private enum KeyCode {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let enter: Int64 = 36
        static let q: Int64 = 12
        static let leftArrow: Int64 = 123
        static let rightArrow: Int64 = 124
        static let downArrow: Int64 = 125
        static let upArrow: Int64 = 126
    }

    private init() {}

    /// True while the event tap is installed.
    var isRunning: Bool { tap != nil }

    /// Applies the persisted preference; safe to call repeatedly.
    func syncWithPreferences() {
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKey.switcherEnabled)
        if enabled, Permissions.shared.accessibility {
            installTap()
            // Build the panel and its SwiftUI tree now: the first hosting-view
            // render costs hundreds of milliseconds, far too slow to pay on
            // the first ⌘Tab.
            let panel = ensurePanel()
            panel.contentViewController?.view.layoutSubtreeIfNeeded()
            BrowserTabService.shared.beginWarming()
        } else {
            removeTap()
            BrowserTabService.shared.endWarming()
        }
    }

    // MARK: - Event tap

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let switcher = Unmanaged<AppSwitcher>.fromOpaque(userInfo).takeUnretainedValue()
                return switcher.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if sessionActive { cancelSession() }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            if sessionActive, !event.flags.contains(modifierFlag) {
                commitSession()
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        guard sessionActive else {
            // A session starts with ⌘Tab, as long as the combo is not claimed
            // by something else (⌘⌥Tab, ⌃⌘Tab…).
            guard keyCode == KeyCode.tab,
                  flags.contains(modifierFlag),
                  !flags.contains(conflictingFlag),
                  !flags.contains(.maskControl)
            else { return Unmanaged.passUnretained(event) }

            beginSession(reversed: flags.contains(.maskShift))
            return nil
        }

        switch keyCode {
        case KeyCode.tab:
            advanceSelection(by: flags.contains(.maskShift) ? -1 : 1)
        case KeyCode.rightArrow:
            advanceSelection(by: 1)
        case KeyCode.leftArrow:
            advanceSelection(by: -1)
        case KeyCode.downArrow:
            moveSelection(by: grid.columns)
        case KeyCode.upArrow:
            moveSelection(by: -grid.columns)
        case KeyCode.q:
            quitSelectedApp()
        case KeyCode.escape:
            cancelSession()
        case KeyCode.enter:
            commitSession()
        default:
            break // Swallow stray keys so they never leak into the focused app.
        }
        return nil
    }

    // MARK: - Session lifecycle

    private func beginSession(reversed: Bool) {
        let baseWindows = WindowEnumerator.listWindows()
        guard !baseWindows.isEmpty else { return }

        // Render immediately with cached tab data (kept warm by app-activation
        // sweeps); a fresh scripting sweep lands shortly after and re-merges.
        let list = WindowEnumerator.mergingTabs(baseWindows, tabs: BrowserTabService.shared.cachedIfEnabled)

        windows = list
        grid = SwitcherGrid.compute(count: list.count, on: screenWithMouse())
        previews = Dictionary(uniqueKeysWithValues: list.compactMap { item in
            item.previewWindowID.flatMap { id in
                WindowPreviewProvider.shared.cachedPreview(for: id).map { (id, $0) }
            }
        })
        userNavigated = false
        selectedIndex = initialSelectionIndex(in: list, reversed: reversed)
        sessionActive = true

        WindowPreviewProvider.shared.refreshPreviews(for: list) { [weak self] windowID, image in
            self?.previews[windowID] = image
        }
        BrowserTabService.shared.refresh { [weak self] tabs in
            self?.applyFreshTabs(tabs, baseWindows: baseWindows)
        }
        scheduleShowPanel()
    }

    /// Where ⌘Tab lands by default: the previous app when there is one, and
    /// otherwise the next entry of the current app — so a quick flick toggles
    /// between two apps, or between two tabs/windows when a single app is open.
    private func initialSelectionIndex(in list: [SwitcherItem], reversed: Bool) -> Int {
        guard list.count > 1 else { return 0 }
        if reversed { return list.count - 1 }

        let frontPid = AppActivationTracker.shared.frontmostPid
        if let frontPid, let firstOther = list.firstIndex(where: { $0.pid != frontPid }) {
            return firstOther
        }
        // Single app: skip the entry the user is looking at (its frontmost
        // window, or that window's active tab) and pick the next one.
        if let current = currentItemIndex(in: list, frontPid: frontPid),
           let next = list.indices.first(where: { $0 != current }) {
            return next
        }
        return 1
    }

    /// The entry representing what is on screen right now: the first MRU item
    /// of the frontmost app — for a tabbed browser window, its active tab.
    private func currentItemIndex(in list: [SwitcherItem], frontPid: pid_t?) -> Int? {
        list.firstIndex { item in
            if let frontPid, item.pid != frontPid { return false }
            switch item.kind {
            case .window: return true
            case let .browserTab(tab): return tab.isActive
            }
        }
    }

    /// Re-merges the item list when the live tab sweep finishes. A selection
    /// the user already moved is kept by id; the default selection is
    /// recomputed so it stays meaningful (e.g. the other tab appears and
    /// becomes the toggle target before the user releases ⌘).
    private func applyFreshTabs(_ tabs: [BrowserTab], baseWindows: [SwitcherItem]) {
        guard sessionActive else { return }
        let merged = WindowEnumerator.mergingTabs(baseWindows, tabs: tabs)
        guard merged != windows else { return }

        let selectedID = windows.indices.contains(selectedIndex) ? windows[selectedIndex].id : nil
        windows = merged
        if userNavigated, let selectedID,
           let index = merged.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else if userNavigated {
            selectedIndex = min(selectedIndex, merged.count - 1)
        } else {
            selectedIndex = initialSelectionIndex(in: merged, reversed: false)
        }
        grid = SwitcherGrid.compute(count: merged.count, on: screenWithMouse())
        resizePanel()
        WindowPreviewProvider.shared.refreshPreviews(for: merged) { [weak self] windowID, image in
            self?.previews[windowID] = image
        }
    }

    func select(index: Int) {
        guard sessionActive, windows.indices.contains(index) else { return }
        userNavigated = true
        selectedIndex = index
    }

    /// Hover-selection from the panel. Ignored until the mouse really moves:
    /// the panel opens centered on the cursor's screen, and the card that
    /// happens to sit under a stationary pointer must not steal the selection.
    func hoverSelect(index: Int) {
        guard sessionActive else { return }
        let mouse = NSEvent.mouseLocation
        if let anchor = hoverAnchor {
            guard hypot(mouse.x - anchor.x, mouse.y - anchor.y) > 4 else { return }
            hoverAnchor = nil
        }
        select(index: index)
    }

    private func advanceSelection(by delta: Int) {
        guard !windows.isEmpty else { return }
        userNavigated = true
        selectedIndex = (selectedIndex + delta + windows.count) % windows.count
    }

    /// Quits the app owning the selected window (⌘Tab → Q), removes its windows
    /// from the grid and keeps the session open — mirroring the system switcher.
    private func quitSelectedApp() {
        guard windows.indices.contains(selectedIndex) else { return }
        let pid = windows[selectedIndex].pid
        NSRunningApplication(processIdentifier: pid)?.terminate()

        let removedBeforeSelection = windows[..<selectedIndex].filter { $0.pid == pid }.count
        windows.removeAll { $0.pid == pid }
        let remaining = Set(windows.compactMap(\.previewWindowID))
        previews = previews.filter { remaining.contains($0.key) }

        guard !windows.isEmpty else {
            endSession()
            return
        }
        selectedIndex = min(max(0, selectedIndex - removedBeforeSelection), windows.count - 1)
        grid = SwitcherGrid.compute(count: windows.count, on: screenWithMouse())
        resizePanel()
    }

    /// Row jump (↑/↓): moves without wrapping so the selection stays put at
    /// the grid edges.
    private func moveSelection(by delta: Int) {
        let target = selectedIndex + delta
        guard windows.indices.contains(target) else { return }
        userNavigated = true
        selectedIndex = target
    }

    /// Activates the current selection. Also used by the panel on click.
    func commitSession() {
        guard sessionActive else { return }
        let selection = windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
        endSession()
        if let selection {
            DispatchQueue.main.async {
                WindowActivator.activate(selection)
            }
        }
    }

    private func cancelSession() {
        guard sessionActive else { return }
        endSession()
    }

    private func endSession() {
        sessionActive = false
        pendingShow?.cancel()
        pendingShow = nil
        WindowPreviewProvider.shared.cancel()
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    /// Shows the panel after a short delay — quick flicks commit before it
    /// fires and never see any UI, exactly like the system switcher.
    private func scheduleShowPanel() {
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionActive else { return }
            self.showPanel()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearanceDelay, execute: work)
    }

    private func showPanel() {
        let panel = ensurePanel()
        hoverAnchor = NSEvent.mouseLocation
        panel.setFrame(centeredFrame(for: grid.panelSize), display: true)
        panel.orderFrontRegardless()
    }

    /// Re-fits the panel after the grid changed mid-session (tab merge, app
    /// quit with Q). Animated only when already on screen, so the size change
    /// reads as intentional instead of a flash.
    private func resizePanel() {
        guard let panel else { return }
        let frame = centeredFrame(for: grid.panelSize)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    private func centeredFrame(for size: CGSize) -> NSRect {
        let screen = screenWithMouse().visibleFrame
        return NSRect(x: screen.midX - size.width / 2,
                      y: screen.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = NSHostingController(rootView: SwitcherView().environmentObject(self))
        self.panel = panel
        return panel
    }

    private func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Grid metrics for one switcher session: large cards laid out in as many
/// rows as needed, sized to the screen under the cursor — no sideways
/// scrolling, no squinting.
struct SwitcherGrid: Equatable {
    let columns: Int
    let rows: Int
    let visibleRows: Int
    let panelSize: CGSize

    static let cardWidth: CGFloat = 288
    static let cardHeight: CGFloat = 214
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 20

    static let empty = SwitcherGrid(columns: 1, rows: 1, visibleRows: 1, panelSize: .zero)

    static func compute(count: Int, on screen: NSScreen) -> SwitcherGrid {
        let usableWidth = screen.visibleFrame.width * 0.92
        let usableHeight = screen.visibleFrame.height * 0.85

        let maxColumns = max(1, Int((usableWidth - padding * 2 + spacing) / (cardWidth + spacing)))
        let columns = min(count, maxColumns)
        let rows = Int(ceil(Double(count) / Double(columns)))

        let maxRows = max(1, Int((usableHeight - padding * 2 + spacing) / (cardHeight + spacing)))
        let visibleRows = min(rows, maxRows)

        let width = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * spacing + padding * 2
        let height = CGFloat(visibleRows) * cardHeight + CGFloat(visibleRows - 1) * spacing + padding * 2
        return SwitcherGrid(columns: columns, rows: rows, visibleRows: visibleRows,
                            panelSize: CGSize(width: width, height: height))
    }
}
