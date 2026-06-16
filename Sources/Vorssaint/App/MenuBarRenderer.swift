// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// A live reading the user can pin next to the menu bar icon. Order here is the
/// order shown in the menu bar.
enum MenuBarMetric: CaseIterable {
    case cpu, gpu, memory, network, battery, power

    var defaultsKey: String {
        switch self {
        case .cpu: return DefaultsKey.menuBarCPU
        case .gpu: return DefaultsKey.menuBarGPU
        case .memory: return DefaultsKey.menuBarMemory
        case .network: return DefaultsKey.menuBarNetwork
        case .battery: return DefaultsKey.menuBarBattery
        case .power: return DefaultsKey.menuBarPower
        }
    }

    static func enabled(in defaults: UserDefaults) -> [MenuBarMetric] {
        allCases.filter { defaults.bool(forKey: $0.defaultsKey) }
    }

    static func anyEnabled(in defaults: UserDefaults) -> Bool {
        allCases.contains { defaults.bool(forKey: $0.defaultsKey) }
    }
}

/// How the Memory metric appears in the menu bar: a colored pressure dot, the
/// percentage of RAM in use, or both.
enum MemoryMenuBarStyle: String, CaseIterable {
    case dot, percent, both

    static var current: MemoryMenuBarStyle {
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.menuBarMemoryStyle) ?? ""
        let style = Defaults.sanitizedMenuBarMemoryStyle(raw)
        return MemoryMenuBarStyle(rawValue: style) ?? .percent
    }

    var showsDot: Bool { self == .dot || self == .both }
    var showsPercent: Bool { self == .percent || self == .both }
}

/// One drawable piece of the menu bar text: plain (adaptive) text, or the memory
/// pressure dot, which carries a green/yellow/red color.
enum MenuBarSegment {
    case text(String)
    case dot(MemoryPressure)
}

/// Builds the compact content shown next to the icon.
///
/// Output is a list of segments so two consumers stay in sync: the status item
/// turns them into a colored attributed string, and the onboarding preview into
/// SwiftUI views. Text segments are fixed-width and right-justified so that, with
/// a monospaced font, the item never jiggles as the numbers change.
enum MenuBarRenderer {
    static func segments(for snapshot: SystemSnapshot, metrics: [MenuBarMetric]) -> [MenuBarSegment] {
        var segments: [MenuBarSegment] = []
        // Single-space separator (not two): keeps metrics readable while trimming
        // the item's width, since macOS hides the widest third-party item first.
        func separate() { if !segments.isEmpty { segments.append(.text(" ")) } }

        for metric in metrics {
            switch metric {
            case .cpu:
                if let usage = snapshot.cpuUsage { separate(); segments.append(.text("CPU " + percent(usage))) }
            case .gpu:
                if let usage = snapshot.gpuUsage { separate(); segments.append(.text("GPU " + percent(usage))) }
            case .memory:
                guard let used = snapshot.memoryUsed, let total = snapshot.memoryTotal, total > 0 else { break }
                separate()
                let style = MemoryMenuBarStyle.current
                if style.showsDot {
                    segments.append(.dot(snapshot.memoryPressure))
                    if style.showsPercent { segments.append(.text(" ")) }
                }
                if style.showsPercent {
                    segments.append(.text("RAM " + percent(Double(used) / Double(total))))
                }
            case .network:
                if let down = snapshot.netDownBytesPerSec, let up = snapshot.netUpBytesPerSec {
                    separate()
                    segments.append(.text("↓" + rjust(MetricFormat.bytesPerSecCompact(down), 5)
                                         + " ↑" + rjust(MetricFormat.bytesPerSecCompact(up), 5)))
                }
            case .battery:
                if let charge = snapshot.power?.chargePercent {
                    separate()
                    let prefix = (snapshot.power?.isCharging ?? false) ? "BAT+ " : "BAT  "
                    segments.append(.text(prefix + percent(Double(charge) / 100.0)))
                }
            case .power:
                if let watts = snapshot.power?.systemWatts {
                    separate()
                    segments.append(.text(rjust(MetricFormat.wattsCompact(watts), 4)))
                }
            }
        }
        return segments
    }

    /// The colored attributed string for the status item. Only the memory dot
    /// gets an explicit color; everything else stays adaptive (the caller applies
    /// the font over the whole run, which does not disturb the dot's color).
    static func attributed(for snapshot: SystemSnapshot, metrics: [MenuBarMetric]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments(for: snapshot, metrics: metrics) {
            switch segment {
            case let .text(string):
                result.append(NSAttributedString(string: string))
            case let .dot(pressure):
                result.append(NSAttributedString(string: "●", attributes: [.foregroundColor: nsColor(for: pressure)]))
            }
        }
        return result
    }

    static func nsColor(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }

    /// A 0...1 fraction as a 3-wide, right-justified percentage: "  5%", " 47%", "100%".
    private static func percent(_ fraction: Double) -> String {
        let value = Int((max(0, min(1, fraction)) * 100).rounded())
        return rjust("\(value)", 3) + "%"
    }

    private static func rjust(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : String(repeating: " ", count: width - string.count) + string
    }
}
