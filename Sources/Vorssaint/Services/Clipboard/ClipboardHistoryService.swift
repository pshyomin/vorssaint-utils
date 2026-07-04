// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

enum ClipboardHistoryMoveDirection {
    case up
    case down
}

/// Opt-in clipboard history. It records plain text and, optionally, copied
/// images and files; keeps a small local history and avoids obvious
/// secret-looking strings by default.
final class ClipboardHistoryService: ObservableObject {
    static let shared = ClipboardHistoryService()

    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var shortcutRegistrationFailed = false
    @Published private(set) var quickBatchEntryIDs: Set<UUID> = []
    @Published var quickQuery = "" {
        didSet {
            if quickQuery != oldValue {
                resetQuickSelection()
            }
        }
    }
    @Published private(set) var quickSelectionIndex = 0
    @Published private(set) var quickSelectionIsVisible = false
    @Published private(set) var quickWindowPresentationID = UUID()

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var registeredShortcut: GlobalShortcut?
    private var pasteTargetApp: NSRunningApplication?
    private let maxCharacters = 20_000

    private init() {
        load()
    }

    func syncWithPreferences() {
        if UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistoryEnabled) {
            start()
            syncHotkey()
        } else {
            stop()
            unregisterHotkey()
        }
    }

    /// Skips capturing pasteboard changes up to the given change count. Quick
    /// tools that rewrite the pasteboard transiently (paste as plain text)
    /// use this so their intermediate writes never churn the history.
    func ignoreNextChange(upTo changeCount: Int) {
        lastChangeCount = max(lastChangeCount, changeCount)
    }

    @discardableResult
    func copy(_ entry: ClipboardHistoryEntry) -> Bool {
        guard writeToPasteboard([entry]) else { return false }
        touch([entry.id])
        return true
    }

    @discardableResult
    func copy(_ selectedEntries: [ClipboardHistoryEntry]) -> Bool {
        guard !selectedEntries.isEmpty, writeToPasteboard(selectedEntries) else { return false }
        touch(selectedEntries.map(\.id))
        return true
    }

    /// Resolves the payload before touching the pasteboard: a stale entry
    /// (image purged from the store, files deleted or on an ejected volume)
    /// must abort with the user's current clipboard intact, not after a
    /// clearContents() already destroyed it.
    private func writeToPasteboard(_ list: [ClipboardHistoryEntry]) -> Bool {
        let pasteboard = NSPasteboard.general

        if list.count == 1, let entry = list.first {
            switch entry.kind {
            case .text:
                pasteboard.clearContents()
                pasteboard.setString(entry.text, forType: .string)
            case .image:
                guard let name = entry.imageFile,
                      let data = ClipboardImageStore.imageData(named: name) else { return false }
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
                // TIFF alongside PNG: some paste targets only take TIFF.
                if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            case .files:
                let urls = entry.filePaths
                    .map { URL(fileURLWithPath: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return false }
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
            }
            lastChangeCount = pasteboard.changeCount
            return true
        }

        // Batches combine as text; images and files only travel one at a time.
        let texts = list.filter { $0.kind == .text }.map(\.text)
        if texts.isEmpty, let first = list.first {
            return writeToPasteboard([first])
        }
        pasteboard.clearContents()
        pasteboard.setString(ClipboardHistoryBatch.combinedText(texts), forType: .string)
        lastChangeCount = pasteboard.changeCount
        return true
    }

    private func touch(_ entryIDs: [UUID]) {
        var didUpdate = false
        let now = Date()
        for entryID in entryIDs {
            if let index = entries.firstIndex(where: { $0.id == entryID }) {
                entries[index].copiedAt = now
                didUpdate = true
            }
        }
        if didUpdate {
            save()
        }
    }

    func togglePin(_ entry: ClipboardHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = entries.remove(at: index)
        if updated.isPinned {
            updated.pinnedAt = nil
            entries.insert(updated, at: firstRecentIndex)
        } else {
            updated.pinnedAt = Date()
            entries.insert(updated, at: 0)
        }
        normalizeEntryOrder()
        save()
    }

    func remove(_ entry: ClipboardHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        var selected = quickBatchEntryIDs
        selected.remove(entry.id)
        quickBatchEntryIDs = selected
        save()
    }

    func clearRecent() {
        entries.removeAll { !$0.isPinned }
        pruneQuickBatchSelection()
        save()
    }

    func clearAll() {
        clearRecent()
    }

    func canMove(_ entry: ClipboardHistoryEntry, _ direction: ClipboardHistoryMoveDirection) -> Bool {
        moveDestination(for: entry, direction) != nil
    }

    func move(_ entry: ClipboardHistoryEntry, _ direction: ClipboardHistoryMoveDirection) {
        guard let from = entries.firstIndex(where: { $0.id == entry.id }),
              let to = moveDestination(for: entry, direction)
        else { return }
        entries.swapAt(from, to)
        save()
    }

    var pinnedEntries: [ClipboardHistoryEntry] {
        entries.filter(\.isPinned)
    }

    var recentEntries: [ClipboardHistoryEntry] {
        entries.filter { !$0.isPinned }
    }

    var filteredQuickEntries: [ClipboardHistoryEntry] {
        filteredEntries(matching: quickQuery)
    }

    var selectedQuickEntryID: UUID? {
        selectedQuickEntry?.id
    }

    var quickBatchCount: Int {
        quickBatchEntries.count
    }

    var selectedQuickEntry: ClipboardHistoryEntry? {
        let matches = filteredQuickEntries
        guard !matches.isEmpty else { return nil }
        return matches[clampedQuickSelectionIndex(for: matches.count)]
    }

    func isQuickBatchSelected(_ entry: ClipboardHistoryEntry) -> Bool {
        quickBatchEntryIDs.contains(entry.id)
    }

    func toggleQuickBatchSelection(_ entry: ClipboardHistoryEntry) {
        // Batches combine as text; images and files stay single-copy items.
        guard entry.kind == .text else { return }
        if let index = filteredQuickEntries.firstIndex(where: { $0.id == entry.id }) {
            quickSelectionIndex = index
        }
        var selected = quickBatchEntryIDs
        if selected.contains(entry.id) {
            selected.remove(entry.id)
        } else {
            selected.insert(entry.id)
        }
        quickBatchEntryIDs = selected
    }

    func toggleSelectedQuickEntryBatchSelection() {
        guard let entry = selectedQuickEntry else { return }
        toggleQuickBatchSelection(entry)
    }

    func clearQuickBatchSelection() {
        quickBatchEntryIDs = []
    }

    func filteredEntries(matching query: String) -> [ClipboardHistoryEntry] {
        let imageLabel = FeatureStrings.clipboard(L10n.shared.language).imageEntryLabel
        let candidates = entries.enumerated().map { index, entry in
            ClipboardHistorySearchCandidate(index: index,
                                            text: entry.searchableText(imageLabel: imageLabel),
                                            isPinned: entry.isPinned)
        }
        return ClipboardHistorySearch.rankedIndexes(candidates: candidates, matching: query)
            .map { entries[$0] }
    }

    func copyQuickEntry(at index: Int) {
        let matches = filteredQuickEntries
        guard matches.indices.contains(index) else { return }
        copyQuickEntry(matches[index])
    }

    func copySelectedQuickEntry() {
        let selectedEntries = quickEntriesForPrimaryAction()
        guard !selectedEntries.isEmpty else { return }
        if selectedEntries.count == 1 {
            copyQuickEntry(selectedEntries[0])
        } else {
            copyQuickEntries(selectedEntries)
        }
    }

    func copySelectedQuickEntryOnly() {
        let selectedEntries = quickEntriesForPrimaryAction()
        guard !selectedEntries.isEmpty else { return }
        if selectedEntries.count == 1 {
            copyOnlyQuickEntry(selectedEntries[0])
        } else {
            copyOnlyQuickEntries(selectedEntries)
        }
    }

    func togglePinSelectedQuickEntry() {
        guard let entry = selectedQuickEntry else { return }
        togglePin(entry)
        quickSelectionIndex = clampedQuickSelectionIndex(for: filteredQuickEntries.count)
    }

    func removeSelectedQuickEntry() {
        guard let entry = selectedQuickEntry else { return }
        remove(entry)
        quickSelectionIndex = clampedQuickSelectionIndex(for: filteredQuickEntries.count)
    }

    func moveQuickSelection(_ delta: Int) {
        let count = filteredQuickEntries.count
        guard count > 0 else {
            quickSelectionIndex = 0
            quickSelectionIsVisible = false
            return
        }
        if !quickSelectionIsVisible {
            quickSelectionIndex = clampedQuickSelectionIndex(for: count)
            quickSelectionIsVisible = true
            return
        }
        quickSelectionIndex = min(max(quickSelectionIndex + delta, 0), count - 1)
    }

    func copyQuickEntry(_ entry: ClipboardHistoryEntry) {
        let copied = copy(entry)
        let target = pasteTargetApp
        hideHistoryWindow()
        pasteTargetApp = nil
        // A stale entry leaves the clipboard untouched; pasting now would
        // paste whatever the user had copied before, out of nowhere.
        guard copied else { return }
        pasteIntoPreviousApp(target)
    }

    func copyQuickEntries(_ selectedEntries: [ClipboardHistoryEntry]) {
        let copied = copy(selectedEntries)
        let target = pasteTargetApp
        hideHistoryWindow()
        pasteTargetApp = nil
        guard copied else { return }
        pasteIntoPreviousApp(target)
    }

    func copyOnlyQuickEntry(_ entry: ClipboardHistoryEntry) {
        copy(entry)
        hideHistoryWindow()
        pasteTargetApp = nil
    }

    func copyOnlyQuickEntries(_ selectedEntries: [ClipboardHistoryEntry]) {
        copy(selectedEntries)
        hideHistoryWindow()
        pasteTargetApp = nil
    }

    private func start() {
        guard timer == nil else {
            isRunning = true
            return
        }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.captureIfChanged()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isRunning = true
        captureIfChanged()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func captureIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Files first: a Finder copy also carries name strings, and a browser
        // image copy also carries URL text, so richer content wins over its
        // own textual fallbacks.
        if UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistoryIncludeImagesFiles) {
            if let paths = Self.copiedFilePaths(from: pasteboard) {
                promoteFiles(paths)
                return
            }
            if let image = Self.copiedPNGImage(from: pasteboard) {
                promoteImage(image)
                return
            }
        }

        guard let text = ClipboardHistoryPasteboardText.preferredText(
            webURLString: Self.webURLString(from: pasteboard),
            plainText: pasteboard.string(forType: .string)
        ) else { return }
        promote(text)
    }

    private static let maxCopiedFiles = 100
    private static let maxImageBytes = 16 * 1024 * 1024
    private static let maxRawImageBytes = 64 * 1024 * 1024

    private static func copiedFilePaths(from pasteboard: NSPasteboard) -> [String]? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty,
              urls.count <= maxCopiedFiles
        else { return nil }
        return urls.map { $0.standardizedFileURL.path }
    }

    private static func copiedPNGImage(from pasteboard: NSPasteboard)
        -> (data: Data, width: Int, height: Int)? {
        let png = pasteboard.data(forType: .png)
        guard let source = png ?? pasteboard.data(forType: .tiff),
              source.count <= maxRawImageBytes,
              let rep = NSBitmapImageRep(data: source),
              rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return nil }
        let data: Data
        if let png {
            data = png
        } else if let converted = rep.representation(using: .png, properties: [:]) {
            data = converted
        } else {
            return nil
        }
        guard data.count <= maxImageBytes else { return nil }
        return (data, rep.pixelsWide, rep.pixelsHigh)
    }

    private func promoteImage(_ image: (data: Data, width: Int, height: Int)) {
        let hash = Self.sha256Hex(image.data)
        if let existing = entries.first(where: { $0.kind == .image && $0.imageHash == hash }) {
            entries.removeAll { $0.id == existing.id }
            insertPromoted(ClipboardHistoryEntry(id: existing.id,
                                                 text: "",
                                                 copiedAt: Date(),
                                                 pinnedAt: existing.pinnedAt,
                                                 kind: .image,
                                                 imageFile: existing.imageFile,
                                                 imageHash: hash,
                                                 imageWidth: existing.imageWidth,
                                                 imageHeight: existing.imageHeight))
        } else {
            guard let name = ClipboardImageStore.store(image.data) else { return }
            insertPromoted(ClipboardHistoryEntry(text: "",
                                                 kind: .image,
                                                 imageFile: name,
                                                 imageHash: hash,
                                                 imageWidth: image.width,
                                                 imageHeight: image.height))
        }
        normalizeEntryOrder()
        trimToLimit()
        save()
    }

    private func promoteFiles(_ paths: [String]) {
        let existing = entries.first(where: { $0.kind == .files && $0.filePaths == paths })
        entries.removeAll { $0.kind == .files && $0.filePaths == paths }
        if let existing {
            insertPromoted(ClipboardHistoryEntry(id: existing.id,
                                                 text: "",
                                                 copiedAt: Date(),
                                                 pinnedAt: existing.pinnedAt,
                                                 kind: .files,
                                                 filePaths: paths))
        } else {
            insertPromoted(ClipboardHistoryEntry(text: "", kind: .files, filePaths: paths))
        }
        normalizeEntryOrder()
        trimToLimit()
        save()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func webURLString(from pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        if let url = urls?.first(where: { isWebURL($0) }) {
            return url.absoluteString
        }
        for type in [NSPasteboard.PasteboardType("public.url"),
                     NSPasteboard.PasteboardType("NSURLPboardType")] {
            if let value = pasteboard.string(forType: type),
               let url = URL(string: value),
               isWebURL(url) {
                return url.absoluteString
            }
        }
        return nil
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private func promote(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxCharacters else { return }
        if UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistorySkipSensitive),
           looksSensitive(text) {
            return
        }

        let existing = entries.first(where: { $0.kind == .text && $0.text == text })
        entries.removeAll { $0.kind == .text && $0.text == text }
        if let existing {
            insertPromoted(ClipboardHistoryEntry(id: existing.id,
                                                 text: text,
                                                 copiedAt: Date(),
                                                 pinnedAt: existing.pinnedAt))
        } else {
            insertPromoted(ClipboardHistoryEntry(text: text))
        }
        normalizeEntryOrder()
        trimToLimit()
        save()
    }

    private func trimToLimit() {
        let limit = Defaults.sanitizedClipboardHistoryLimit(
            UserDefaults.standard.integer(forKey: DefaultsKey.clipboardHistoryLimit)
        )
        let pinned = entries.filter(\.isPinned)
        var recent = entries.filter { !$0.isPinned }
        if recent.count > limit {
            recent.removeSubrange(limit..<recent.count)
        }
        entries = pinned + recent
    }

    private var firstRecentIndex: Int {
        entries.firstIndex { !$0.isPinned } ?? entries.endIndex
    }

    private func insertPromoted(_ entry: ClipboardHistoryEntry) {
        if entry.isPinned {
            entries.insert(entry, at: 0)
        } else {
            entries.insert(entry, at: firstRecentIndex)
        }
    }

    private func normalizeEntryOrder() {
        let pinned = entries.filter(\.isPinned)
        let recent = entries.filter { !$0.isPinned }
        entries = pinned + recent
    }

    private func moveDestination(for entry: ClipboardHistoryEntry,
                                 _ direction: ClipboardHistoryMoveDirection) -> Int? {
        let groupIndices = entries.indices.filter { entries[$0].isPinned == entry.isPinned }
        guard let groupPosition = groupIndices.firstIndex(where: { entries[$0].id == entry.id }) else {
            return nil
        }
        switch direction {
        case .up:
            guard groupPosition > groupIndices.startIndex else { return nil }
            return groupIndices[groupIndices.index(before: groupPosition)]
        case .down:
            let next = groupIndices.index(after: groupPosition)
            guard next < groupIndices.endIndex else { return nil }
            return groupIndices[next]
        }
    }

    private func looksSensitive(_ text: String) -> Bool {
        ClipboardHistorySensitiveText.looksSensitive(text)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.clipboardHistoryEntries),
              let decoded = try? JSONDecoder().decode([ClipboardHistoryEntry].self, from: data)
        else { return }
        entries = decoded
        normalizeEntryOrder()
        trimToLimit()
        // Sweep image files that lost their entry (crash between write and save).
        ClipboardImageStore.cleanup(keeping: Set(entries.compactMap(\.imageFile)))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.clipboardHistoryEntries)
        ClipboardImageStore.cleanup(keeping: Set(entries.compactMap(\.imageFile)))
    }

    // MARK: - Shortcut

    func syncHotkey() {
        let wanted = UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistoryEnabled)
            && UserDefaults.standard.bool(forKey: DefaultsKey.clipboardHistoryShortcutEnabled)
        wanted ? registerHotkey() : unregisterHotkey()
    }

    private func registerHotkey() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.clipboardHistoryShortcut,
                                            fallback: .clipboardDefault)
        if hotKeyRef != nil, registeredShortcut == shortcut { return }
        unregisterHotkey()
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
                guard id.signature == 0x5655_434C, id.id == 3
                else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<ClipboardHistoryService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { service.toggleHistoryWindow() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: 0x5655_434C, id: 3) // 'VUCL'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.carbonKeyCode,
                                         shortcut.carbonModifiers,
                                         id, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registeredShortcut = shortcut
            shortcutRegistrationFailed = false
        } else {
            hotKeyRef = nil
            registeredShortcut = nil
            shortcutRegistrationFailed = true
        }
    }

    private func unregisterHotkey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registeredShortcut = nil
        shortcutRegistrationFailed = false
    }

    // MARK: - Quick window

    func toggleHistoryWindow() {
        if panel?.isVisible == true {
            hideHistoryWindow()
        } else {
            showHistoryWindow()
        }
    }

    func showHistoryWindow() {
        let panel = ensurePanel()
        rememberPasteTarget()
        quickWindowPresentationID = UUID()
        quickQuery = ""
        clearQuickBatchSelection()
        resetQuickSelection()
        position(panel)
        installKeyMonitor(for: panel)
        installDismissMonitors(for: panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hideHistoryWindow() {
        removeKeyMonitor()
        removeDismissMonitors()
        panel?.orderOut(nil)
        clearQuickBatchSelection()
    }

    private func rememberPasteTarget() {
        let ownBundleID = Bundle.main.bundleIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != ownBundleID,
              app.activationPolicy == .regular,
              !app.isTerminated
        else {
            pasteTargetApp = nil
            return
        }
        pasteTargetApp = app
    }

    private func pasteIntoPreviousApp(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.postPasteShortcut()
        }
    }

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: CGKeyCode(kVK_ANSI_V),
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_ANSI_V),
                                  keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.title = FeatureStrings.clipboard(L10n.shared.language).title
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingController(rootView: ClipboardQuickPanelView())
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let size = panel.contentViewController?.view.fittingSize ?? NSSize(width: 520, height: 560)
        let screen = NSScreen.withMouse.visibleFrame
        let x = screen.midX - size.width / 2
        let y = min(screen.maxY - size.height - 54, screen.midY - size.height / 2)
        panel.setFrame(NSRect(x: max(screen.minX + 16, min(x, screen.maxX - size.width - 16)),
                              y: max(screen.minY + 16, y),
                              width: size.width,
                              height: size.height),
                       display: true,
                       animate: false)
    }

    private func installKeyMonitor(for panel: NSPanel) {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.hideHistoryWindow()
                return nil
            }
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                let enterModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
                if enterModifiers == [.command] {
                    self.toggleSelectedQuickEntryBatchSelection()
                    return nil
                }
                if enterModifiers == [.shift] {
                    self.copySelectedQuickEntryOnly()
                    return nil
                }
                if enterModifiers.isEmpty {
                    self.copySelectedQuickEntry()
                    return nil
                }
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if modifiers == [.option], event.keyCode == UInt16(kVK_ANSI_P) {
                self.togglePinSelectedQuickEntry()
                return nil
            }
            if modifiers == [.option],
               event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                self.removeSelectedQuickEntry()
                return nil
            }
            if event.keyCode == UInt16(kVK_DownArrow) {
                self.moveQuickSelection(1)
                return nil
            }
            if event.keyCode == UInt16(kVK_UpArrow) {
                self.moveQuickSelection(-1)
                return nil
            }
            if modifiers == [.command],
               let index = Self.digitIndex(for: event.keyCode) {
                self.copyQuickEntry(at: index)
                return nil
            }
            return event
        }
    }

    private func installDismissMonitors(for panel: NSPanel) {
        removeDismissMonitors()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return event }
            if event.window !== panel, !Self.mouseIsInside(panel) {
                self.hideHistoryWindow()
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else { return }
            if event.windowNumber != panel.windowNumber, !Self.mouseIsInside(panel) {
                self.hideHistoryWindow()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            self.hideHistoryWindow()
        }
    }

    private static func mouseIsInside(_ panel: NSPanel) -> Bool {
        panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func removeDismissMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func resetQuickSelection() {
        quickSelectionIndex = ClipboardHistorySelection.initialIndex(totalCount: filteredQuickEntries.count)
        quickSelectionIsVisible = false
    }

    private var quickBatchEntries: [ClipboardHistoryEntry] {
        let allIDs = entries.map(\.id)
        let indexes = ClipboardHistoryBatch.orderedSelectedIndexes(allIDs: allIDs,
                                                                  selectedIDs: quickBatchEntryIDs)
        return indexes.map { entries[$0] }
    }

    private func quickEntriesForPrimaryAction() -> [ClipboardHistoryEntry] {
        let batch = quickBatchEntries
        if !batch.isEmpty { return batch }
        guard let entry = selectedQuickEntry else { return [] }
        return [entry]
    }

    private func pruneQuickBatchSelection() {
        let validIDs = Set(entries.map(\.id))
        quickBatchEntryIDs = Set(quickBatchEntryIDs.filter { validIDs.contains($0) })
    }

    private static func digitIndex(for keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        default: return nil
        }
    }

    private func clampedQuickSelectionIndex(for count: Int) -> Int {
        min(max(quickSelectionIndex, 0), max(count - 1, 0))
    }
}

/// File-backed storage for copied images: PNGs live in Application Support
/// (UserDefaults would balloon with base64), named by UUID and swept against
/// the live entry list after every save.
enum ClipboardImageStore {
    private static let thumbnails = NSCache<NSString, NSImage>()

    static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier
        else { return nil }
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("ClipboardImages", isDirectory: true)
    }

    static func store(_ data: Data) -> String? {
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".png"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        return name
    }

    static func imageData(named name: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// Downsampled preview for list rows, cached; loading full PNGs per row
    /// would drag the quick window.
    static func thumbnail(named name: String) -> NSImage? {
        if let cached = thumbnails.object(forKey: name as NSString) {
            return cached
        }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(name)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        thumbnails.setObject(image, forKey: name as NSString)
        return image
    }

    static func cleanup(keeping names: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil)
        else { return }
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            thumbnails.removeObject(forKey: file.lastPathComponent as NSString)
        }
    }
}
