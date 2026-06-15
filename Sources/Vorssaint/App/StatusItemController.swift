import AppKit
import Combine

/// Owns the menu bar presence: the black hole glyph with its active/inactive
/// states, the click micro-interaction, the optional countdown title and the
/// tooltip. Click handling is delegated back to the AppDelegate.
final class StatusItemController {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    private(set) var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var titleTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    var button: NSStatusBarButton? { statusItem.button }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The menu bar item is the app's only entry point, so it must never be
        // lost for good. An empty behavior set keeps it from being dragged off the
        // bar (reordering still works), and forcing isVisible undoes any hidden
        // state macOS may have persisted from a previous removal. If it ever does
        // go missing, re-opening the app restores it (see applicationShouldHandleReopen).
        statusItem.behavior = []
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = BlackHoleGlyph.image(active: false)
            // Fully monospaced (not just digits) so the fixed-width metric fields
            // keep a constant pixel width and the item never jiggles.
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.wantsLayer = true
        }

        bind()
        refresh()
        syncMonitorMode()
        updateIconAppearance()

        titleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        titleTimer?.tolerance = 5
    }

    private func bind() {
        KeepAwakeManager.shared.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateIconAppearance()
                self?.refresh()
            }
            .store(in: &cancellables)

        UpdateService.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIconAppearance() }
            .store(in: &cancellables)

        KeepAwakeManager.shared.$endDate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        L10n.shared.$language
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        SystemMonitor.shared.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard MenuBarMetric.anyEnabled(in: .standard) else { return }
                self?.refresh()
            }
            .store(in: &cancellables)

        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil,
                                                                  queue: .main) { [weak self] _ in
            self?.syncMonitorMode()
            self?.refresh()
        }
    }

    deinit {
        // The controller lives for the whole process today, but tear down cleanly
        // so a future "recreate the status item" path can't leak a firing timer or
        // a block observer that outlives this instance.
        titleTimer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Keeps the background sampler in step with the menu bar settings: it runs
    /// continuously only while at least one metric is pinned to the menu bar.
    private func syncMonitorMode() {
        let defaults = UserDefaults.standard
        var interval = defaults.integer(forKey: DefaultsKey.monitorInterval)
        if interval <= 0 { interval = 2 }
        SystemMonitor.shared.setInterval(seconds: interval)
        SystemMonitor.shared.setMenuBarActive(MenuBarMetric.anyEnabled(in: defaults))
    }

    /// Reflects keep-awake state and an available update in the icon: the glyph
    /// turns blue when there's an update, for a discreet bit of attention.
    private func updateIconAppearance() {
        guard let button = statusItem?.button else { return }
        if case .available = UpdateService.shared.state {
            button.image = BlackHoleGlyph.attentionImage()
        } else {
            button.image = BlackHoleGlyph.image(active: KeepAwakeManager.shared.isActive)
        }
    }

    @objc private func clicked() {
        pulse()
        if NSApp.currentEvent?.type == .rightMouseUp {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    /// Quick, springy scale dip — the click micro-interaction.
    private func pulse() {
        guard let layer = statusItem.button?.layer else { return }
        // AppKit resets layer geometry on layout, so re-center the anchor at
        // click time to scale from the middle of the icon.
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 0.84, 1.06, 1.0]
        animation.keyTimes = [0, 0.35, 0.72, 1]
        animation.duration = 0.28
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut),
        ]
        layer.add(animation, forKey: "vorssaint.pulse")
    }

    /// Updates the countdown title and tooltip from the current session state.
    func refresh() {
        guard let button = statusItem?.button else { return }
        let manager = KeepAwakeManager.shared
        let strings = L10n.shared.s
        let defaults = UserDefaults.standard
        let font = button.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

        // Compose the title from the keep-awake countdown (when shown) followed by
        // the pinned live metrics. Built attributed so the memory pressure dot can
        // carry its green/yellow/red color; all other runs stay adaptive.
        let title = NSMutableAttributedString()
        if manager.isActive, defaults.bool(forKey: DefaultsKey.showCountdown) {
            let countdown: String
            if let end = manager.endDate {
                let remaining = max(0, Int(end.timeIntervalSinceNow))
                let hours = remaining / 3600
                let minutes = (remaining % 3600) / 60
                countdown = hours > 0 ? String(format: "%d:%02d", hours, minutes) : "\(max(minutes, 1)) min"
            } else {
                countdown = "∞"
            }
            title.append(NSAttributedString(string: countdown))
        }
        let metrics = MenuBarMetric.enabled(in: defaults)
        if !metrics.isEmpty {
            let metricsTitle = MenuBarRenderer.attributed(for: SystemMonitor.shared.snapshot, metrics: metrics)
            if metricsTitle.length > 0 {
                if title.length > 0 { title.append(NSAttributedString(string: "  ")) }
                title.append(metricsTitle)
            }
        }

        if title.length == 0 {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            let full = NSMutableAttributedString(string: " ")
            full.append(title)
            full.addAttribute(.font, value: font, range: NSRange(location: 0, length: full.length))
            button.attributedTitle = full
            button.imagePosition = .imageLeading
        }

        if manager.isActive {
            if let end = manager.endDate {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                button.toolTip = "\(strings.statusActiveUntil) \(formatter.string(from: end))"
            } else {
                button.toolTip = strings.statusActiveIndefinite
            }
        } else {
            button.toolTip = strings.statusIdleTooltip
        }
    }
}

/// The official mark, bundled as a template image so it adapts to light and
/// dark menu bars. Active renders at full strength; inactive is dimmed and
/// discreet.
enum BlackHoleGlyph {
    /// Logical size of the glyph in the menu bar, in points.
    private static let pointSize = NSSize(width: 20, height: 14)

    /// Both scale representations go into one NSImage — loading the 1x file
    /// alone would render blurry on Retina menu bars.
    private static let base: NSImage? = {
        let image = NSImage(size: pointSize)
        for resource in ["MenuBarIcon", "MenuBarIcon@2x"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data)
            else { continue }
            rep.size = pointSize
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }()

    static func image(active: Bool) -> NSImage? {
        guard let base else { return fallback(active: active) }
        if active { return base }

        let dimmed = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.55)
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }

    /// A blue, full-strength glyph used to flag an available update. Non-template
    /// (a real color), drawn by masking blue into the glyph's shape.
    static func attentionImage() -> NSImage? {
        guard let base else { return fallback(active: true) }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.systemBlue.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// Keeps a recognizable presence if the bundled asset is ever missing
    /// (e.g. running the bare binary from build/).
    private static func fallback(active: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: AppInfo.name)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: active ? .bold : .regular))
        image?.isTemplate = true
        return image
    }
}
