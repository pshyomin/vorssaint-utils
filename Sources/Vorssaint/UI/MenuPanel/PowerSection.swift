// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The "Power" card: how much the Mac is drawing overall, from the adapter, and
/// to/from the battery. Rows that the hardware cannot report are simply hidden;
/// a Mac that reports nothing shows a short note instead.
struct PowerSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    var collapsible = true
    @AppStorage(DefaultsKey.monitorGraphPower) private var showGraph = true
    @AppStorage(DefaultsKey.monitorPwrSystem) private var pwrSystem = true
    @AppStorage(DefaultsKey.monitorPwrAdapter) private var pwrAdapter = true
    @AppStorage(DefaultsKey.monitorPwrBattery) private var pwrBattery = true
    @AppStorage(DefaultsKey.monitorPwrHealth) private var pwrHealth = true

    var body: some View {
        Group {
            if shouldShow {
                PanelSection(.power, title: l10n.s.powerSection, collapsible: collapsible) {
                    VStack(alignment: .leading, spacing: 10) {
                        content
                    }
                    .panelCard()
                }
            } else {
                EmptyView()
            }
        }
    }

    private var anyItemEnabled: Bool { pwrSystem || pwrAdapter || pwrBattery || pwrHealth }

    /// Show the card when an enabled item actually has data, or — when items are
    /// enabled but the Mac reports no power at all — to surface the "unavailable"
    /// note. All items off → hide entirely.
    private var shouldShow: Bool {
        guard anyItemEnabled else { return false }
        guard let power = monitor.snapshot.power else { return true }
        if power.isEmpty { return true }
        return hasVisibleContent(power)
    }

    private func hasVisibleContent(_ power: PowerReading) -> Bool {
        if pwrSystem, power.systemWatts != nil { return true }
        if pwrAdapter, power.externalConnected, power.adapterWatts != nil { return true }
        if pwrBattery, power.hasBattery, power.batteryWatts != nil { return true }
        if pwrHealth, power.healthPercent != nil { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        if let power = monitor.snapshot.power, !power.isEmpty {
            if pwrSystem, let watts = power.systemWatts {
                row(icon: "bolt.fill", color: .orange,
                    label: l10n.s.powerSystem, value: MetricFormat.watts(watts))
                if showGraph, monitor.snapshot.systemPowerHistory.count >= 2 {
                    Sparkline(values: monitor.snapshot.systemPowerHistory, color: .orange)
                        .frame(height: 26)
                }
            }
            if pwrAdapter, power.externalConnected, let adapter = power.adapterWatts {
                row(icon: "powerplug.fill", color: .accentColor,
                    label: l10n.s.powerAdapter, value: MetricFormat.watts(adapter),
                    caption: adapterCaption(power))
            }
            if pwrBattery, power.hasBattery, let flow = power.batteryWatts {
                row(icon: flow >= 0 ? "battery.100.bolt" : "battery.50",
                    color: flow >= 0 ? .green : .secondary,
                    label: l10n.s.powerBattery,
                    value: MetricFormat.watts(abs(flow)),
                    caption: flow >= 0 ? l10n.s.powerCharging : l10n.s.powerOnBattery)
            }
            if pwrHealth, let health = power.healthPercent {
                row(icon: "heart.fill", color: .pink,
                    label: l10n.s.powerHealth,
                    value: "\(Int(health.rounded()))%",
                    caption: power.cycleCount.map { "\($0) \(l10n.s.powerCycles)" })
            }
        } else {
            Text(l10n.s.powerUnavailable)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func adapterCaption(_ power: PowerReading) -> String {
        if let rated = power.adapterMaxWatts {
            return String(format: l10n.s.powerAdapterMaxFormat, MetricFormat.watts(rated))
        }
        return l10n.s.powerPluggedIn
    }

    private func row(icon: String, color: Color, label: String, value: String, caption: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}
