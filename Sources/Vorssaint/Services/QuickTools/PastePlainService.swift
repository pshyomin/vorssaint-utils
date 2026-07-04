// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox

/// Pastes the clipboard as plain text on a global shortcut: strips fonts,
/// colors and links, pastes, and quietly puts the original rich content back
/// so later normal pastes keep their formatting. Requires Accessibility for
/// the synthesized ⌘V.
final class PastePlainService: ObservableObject {
    static let shared = PastePlainService()

    @Published private(set) var shortcutRegistrationFailed = false

    private let hotkey = QuickToolHotkey(id: 10)

    /// The rich content whose restore is still scheduled, keyed by the change
    /// count of our own plain write. A second shortcut press inside that
    /// window must reuse this snapshot — the pasteboard currently holds the
    /// stripped text, and re-snapshotting it would lose the original for good.
    private var pendingRestore: (snapshot: [NSPasteboardItem], plainChangeCount: Int)?
    private var restoreWork: DispatchWorkItem?

    private init() {
        hotkey.onPress = { [weak self] in self?.performPastePlain() }
    }

    func syncWithPreferences() {
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKey.pastePlainEnabled)
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.pastePlainShortcut,
                                            fallback: .pastePlainDefault)
        shortcutRegistrationFailed = !hotkey.sync(enabled: enabled, shortcut: shortcut)
    }

    func suspend() {
        hotkey.unregister()
    }

    func performPastePlain() {
        guard AXIsProcessTrusted() else { return }
        let pasteboard = NSPasteboard.general
        guard let plain = Self.plainText(from: pasteboard), !plain.isEmpty else { return }

        // Deep-copy the current content first: items can't be re-attached to
        // the pasteboard once it is cleared. If the pasteboard still holds our
        // own plain write from a press moments ago, keep that press's rich
        // snapshot instead of photographing the stripped text.
        let snapshot: [NSPasteboardItem]
        if let pending = pendingRestore, pasteboard.changeCount == pending.plainChangeCount {
            snapshot = pending.snapshot
        } else {
            snapshot = Self.snapshot(of: pasteboard)
        }
        restoreWork?.cancel()

        pasteboard.clearContents()
        pasteboard.setString(plain, forType: .string)
        let plainChangeCount = pasteboard.changeCount
        ClipboardHistoryService.shared.ignoreNextChange(upTo: plainChangeCount)
        pendingRestore = (snapshot, plainChangeCount)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Self.postPasteShortcut()
        }

        // Put the rich original back once the paste went through, unless the
        // user copied something new in the meantime.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restoreWork = nil
            self.pendingRestore = nil
            guard pasteboard.changeCount == plainChangeCount, !snapshot.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(snapshot)
            ClipboardHistoryService.shared.ignoreNextChange(upTo: pasteboard.changeCount)
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The clipboard's text without any formatting: the plain string when
    /// present, else the text of its RTF or HTML content.
    static func plainText(from pasteboard: NSPasteboard) -> String? {
        if let plain = pasteboard.string(forType: .string) {
            return plain
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return attributed.string
        }
        if let html = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: html, documentAttributes: nil) {
            return attributed.string
        }
        return nil
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
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
}
