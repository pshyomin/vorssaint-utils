// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

/// Brings a switcher selection to the front: unminimizes if needed, makes the
/// exact window the app's focused/main Accessibility window and activates the
/// owning app. The focus pass is repeated after activation because Space changes
/// are asynchronous and some apps settle their main window one run-loop later.
enum WindowActivator {
    private static let focusRetryDelay: TimeInterval = 0.12

    static func activate(_ item: SwitcherItem) {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }

        app.unhide()
        focusWindow(windowID: item.windowID, pid: item.pid)
        activateApp(app)

        let pid = item.pid
        let windowID = item.windowID
        DispatchQueue.main.asyncAfter(deadline: .now() + focusRetryDelay) {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
            focusWindow(windowID: windowID, pid: pid)
            activateApp(app)
        }
    }

    private static func activateApp(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        if !app.activate(from: NSRunningApplication.current, options: [.activateAllWindows]) {
            app.activate(options: [.activateAllWindows])
        }
    }

    @discardableResult
    private static func focusWindow(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard Permissions.shared.accessibility else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindow = axElement(windowID: windowID, in: axApp) else { return false }

        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXMainWindowAttribute as CFString, axWindow)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private static func axElement(windowID: CGWindowID, in axApp: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement]
        else { return nil }

        for axWindow in axWindows {
            if AXWindowResolver.windowID(for: axWindow) == windowID {
                return axWindow
            }
        }
        return nil
    }
}
