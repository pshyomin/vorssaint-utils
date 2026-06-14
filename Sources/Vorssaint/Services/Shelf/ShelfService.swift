import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A floating "shelf" that holds files, images, text and links you drop on it,
/// to drag back out into any app later. It's summoned at the cursor by a global
/// shortcut (⌃⌥⌘D) or, optionally, by shaking the mouse mid-drag. Items live
/// only while the app runs.
///
/// No permissions required: the shortcut is a Carbon hot key, and the shake
/// detector is a passive global mouse monitor.
final class ShelfService: ObservableObject {
    static let shared = ShelfService()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        enum Payload: Equatable {
            case file(URL)
            case text(String)
            case link(URL)
        }
        let payload: Payload
        let title: String
        let icon: NSImage
        let isImage: Bool

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var items: [Item] = [] {
        didSet { scheduleRefit() }
    }
    /// Ids of tiles the user has selected; a drag of any selected tile drags
    /// the whole selection out together.
    @Published private(set) var selection: Set<UUID> = []

    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var mouseMonitor: Any?
    private var shakeSamples: [(t: TimeInterval, x: CGFloat)] = []
    private var lastSummon: TimeInterval = 0
    /// Drag-pasteboard change count captured at mouse-down. A shake only counts
    /// when this has since changed — i.e. an actual file/image/text drag is in
    /// progress. Moving a window writes nothing to the drag pasteboard, so it
    /// leaves this untouched and never summons the shelf.
    private var dragPasteboardBaseline = 0

    private let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VorssaintShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        if UserDefaults.standard.bool(forKey: DefaultsKey.shelfEnabled) {
            registerHotkey()
            syncShakeMonitor()
        } else {
            unregisterHotkey()
            stopShakeMonitor()
            hide()
        }
    }

    /// Re-reads only the shake sub-preference (called when the user toggles it).
    func syncShakeMonitor() {
        let wanted = UserDefaults.standard.bool(forKey: DefaultsKey.shelfEnabled)
            && UserDefaults.standard.bool(forKey: DefaultsKey.shelfShakeToOpen)
        if wanted { startShakeMonitor() } else { stopShakeMonitor() }
    }

    // MARK: - Triggers

    private func registerHotkey() {
        guard hotKeyRef == nil else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                if let event {
                    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &id)
                }
                // Not our hotkey: hand it back so the keep-awake handler on the
                // same dispatch target still receives ⌃⌥⌘K. Returning noErr would
                // swallow it.
                guard id.id == 2 else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<ShelfService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { service.toggle() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: 0x5655_5348, id: 2) // 'VUSH'
        RegisterEventHotKey(UInt32(kVK_ANSI_D),
                            UInt32(controlKey | optionKey | cmdKey),
                            id, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotkey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func startShakeMonitor() {
        guard mouseMonitor == nil else { return }
        dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                // Capture the drag pasteboard before any drag starts; a content
                // drag will bump it, a window move won't.
                self.dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
                self.shakeSamples.removeAll()
            } else {
                self.handleDrag(event)
            }
        }
    }

    private func stopShakeMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        shakeSamples.removeAll()
    }

    /// Detects a back-and-forth shake of the pointer during a drag: enough
    /// horizontal direction reversals and travel in a short window.
    private func handleDrag(_ event: NSEvent) {
        let t = event.timestamp
        shakeSamples.append((t, NSEvent.mouseLocation.x))
        shakeSamples.removeAll { t - $0.t > 0.5 }
        guard shakeSamples.count >= 5 else { return }

        var reversals = 0
        var travel: CGFloat = 0
        var lastDirection = 0
        for i in 1..<shakeSamples.count {
            let dx = shakeSamples[i].x - shakeSamples[i - 1].x
            travel += abs(dx)
            let direction = dx > 6 ? 1 : (dx < -6 ? -1 : 0)
            if direction != 0 {
                if lastDirection != 0, direction != lastDirection { reversals += 1 }
                lastDirection = direction
            }
        }
        if reversals >= 3, travel > 220, t - lastSummon > 1.0 {
            // Only when content is actually being dragged — not when a window is
            // being moved (nothing droppable, so the shelf shouldn't appear).
            guard NSPasteboard(name: .drag).changeCount != dragPasteboardBaseline else { return }
            lastSummon = t
            shakeSamples.removeAll()
            DispatchQueue.main.async { [weak self] in self?.summon() }
        }
    }

    // MARK: - Items

    /// Order matters for fidelity: a file is always a file, but a web image
    /// drag carries both an image and its page URL — prefer the image, and
    /// only fall back to treating a URL as a link when nothing richer exists.
    func accept(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { self?.addFile(url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async { self?.addImage(image) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        url.isFileURL ? self?.addFile(url) : self?.addLink(url)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { [weak self] string, _ in
                    guard let string = string as? String else { return }
                    DispatchQueue.main.async { self?.addText(string) }
                }
            }
        }
        return handled
    }

    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        selection.remove(id)
    }

    /// Removes several items at once — used after a successful drag-out so the
    /// tiles you dropped elsewhere leave the shelf.
    func removeItems(_ ids: [UUID]) {
        let set = Set(ids)
        items.removeAll { set.contains($0.id) }
        selection.subtract(set)
    }

    func clear() {
        items = []
        selection = []
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectedItems() -> [Item] {
        items.filter { selection.contains($0.id) }
    }

    /// The pasteboard representation used when dragging an item out of the shelf.
    func pasteboardWriter(for item: Item) -> NSPasteboardWriting {
        switch item.payload {
        case let .file(url): return url as NSURL
        case let .text(text): return text as NSString
        case let .link(url): return url as NSURL
        }
    }

    private func addFile(_ url: URL) {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp"]
        let isImage = imageExtensions.contains(url.pathExtension.lowercased())
        let icon = (isImage ? NSImage(contentsOf: url) : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
        append(Item(payload: .file(url), title: url.lastPathComponent, icon: icon, isImage: isImage))
    }

    private func addImage(_ image: NSImage) {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).png")
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            append(Item(payload: .file(url), title: L10n.shared.s.shelfItemImage, icon: image, isImage: true))
        }
    }

    private func addText(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let icon = symbol("doc.plaintext")
        append(Item(payload: .text(string), title: String(firstLine.prefix(48)), icon: icon, isImage: false))
    }

    private func addLink(_ url: URL) {
        append(Item(payload: .link(url), title: url.host ?? url.absoluteString, icon: symbol("link"), isImage: false))
    }

    private func append(_ item: Item) {
        items.append(item)
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: - Panel

    func toggle() {
        isVisible ? hide() : summon()
    }

    func summon() {
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Re-fits the panel to its content (anchored at the top-left) after items
    /// change while it's on screen — e.g. dropping a file onto a shelf that was
    /// summoned empty by a shake. Deferred so SwiftUI lays out first.
    private func scheduleRefit() {
        DispatchQueue.main.async { [weak self] in self?.refitIfVisible() }
    }

    private func refitIfVisible() {
        guard let panel, panel.isVisible else { return }
        let view = panel.contentViewController!.view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true, animate: false)
    }

    private func position(_ panel: NSPanel) {
        let view = panel.contentViewController!.view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.withMouse.visibleFrame
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 16
        x = min(max(screen.minX + 8, x), screen.maxX - size.width - 8)
        y = min(max(screen.minY + 8, y), screen.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Not movable by background: dragging a tile must start an item drag,
        // not move the whole panel.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingController(rootView: ShelfView().environmentObject(self))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        self.panel = panel
        return panel
    }
}
