// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import UniformTypeIdentifiers

/// The "Monitor" settings page: pick what shows next to the menu bar icon, how
/// often it refreshes, which blocks appear in the panel, and which metrics draw
/// a history graph. Everything is opt-in or reversible, so users keep only what
/// they find useful.
struct MonitorSettings: View {
    @ObservedObject private var l10n = L10n.shared

    @AppStorage(DefaultsKey.menuBarCPU) private var menuBarCPU = false
    @AppStorage(DefaultsKey.menuBarGPU) private var menuBarGPU = false
    @AppStorage(DefaultsKey.menuBarMemory) private var menuBarMemory = false
    @AppStorage(DefaultsKey.menuBarNetwork) private var menuBarNetwork = false
    @AppStorage(DefaultsKey.menuBarBattery) private var menuBarBattery = false
    @AppStorage(DefaultsKey.menuBarPower) private var menuBarPower = false
    @AppStorage(DefaultsKey.menuBarMemoryStyle) private var memoryStyle = "percent"
    @AppStorage(DefaultsKey.monitorInterval) private var interval = 2
    @AppStorage(DefaultsKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius.rawValue
    @AppStorage(DefaultsKey.monitorShowFanControlBeta) private var showFanControlBeta = false

    @AppStorage(DefaultsKey.monitorGraphCPU) private var graphCPU = true
    @AppStorage(DefaultsKey.monitorGraphGPU) private var graphGPU = true
    @AppStorage(DefaultsKey.monitorGraphMemory) private var graphMemory = true
    @AppStorage(DefaultsKey.monitorGraphNetwork) private var graphNetwork = true
    @AppStorage(DefaultsKey.monitorGraphPower) private var graphPower = true
    @AppStorage(DefaultsKey.monitorGraphBattery) private var graphBattery = true

    var body: some View {
        Form {
            Section(l10n.s.monitorMenuBarSection) {
                Toggle(l10n.s.monitorShowCPU, isOn: $menuBarCPU)
                Toggle(l10n.s.monitorShowGPU, isOn: $menuBarGPU)
                Toggle(l10n.s.monitorShowMemory, isOn: $menuBarMemory)
                if menuBarMemory {
                    Picker(l10n.s.monitorMemoryStyleLabel, selection: $memoryStyle) {
                        Text(l10n.s.memoryStyleDot).tag("dot")
                        Text(l10n.s.memoryStylePercent).tag("percent")
                        Text(l10n.s.memoryStyleBoth).tag("both")
                    }
                    .pickerStyle(.segmented)
                }
                Toggle(l10n.s.monitorShowNetwork, isOn: $menuBarNetwork)
                Toggle(l10n.s.batteryLabel, isOn: $menuBarBattery)
                Toggle(l10n.s.monitorShowPowerLabel, isOn: $menuBarPower)
                Text(l10n.s.monitorMenuBarCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(l10n.s.monitorIntervalLabel, selection: $interval) {
                    Text(l10n.s.monitorInterval1).tag(1)
                    Text(l10n.s.monitorInterval2).tag(2)
                    Text(l10n.s.monitorInterval5).tag(5)
                }
                Picker(l10n.s.temperatures, selection: $temperatureUnit) {
                    Text("°C").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                }
                .pickerStyle(.segmented)
            }
            Section(l10n.s.monitorPanelSection) {
                MonitorPanelConfig()
                Text(l10n.s.monitorPanelConfigHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(l10n.s.fanControlBetaSection) {
                Toggle(l10n.s.fanControlBetaShow, isOn: $showFanControlBeta)
                Text(l10n.s.fanControlBetaCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(l10n.s.monitorOrderSection) {
                PanelOrderEditor()
                Text(l10n.s.monitorOrderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(l10n.s.monitorGraphsSection) {
                Toggle(l10n.s.monitorShowCPU, isOn: $graphCPU)
                Toggle(l10n.s.monitorShowGPU, isOn: $graphGPU)
                Toggle(l10n.s.monitorShowMemory, isOn: $graphMemory)
                Toggle(l10n.s.monitorShowNetwork, isOn: $graphNetwork)
                Toggle(l10n.s.monitorShowPowerLabel, isOn: $graphPower)
                Toggle(l10n.s.batteryLabel, isOn: $graphBattery)
                Text(l10n.s.monitorGraphsCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            interval = Defaults.sanitizedMonitorInterval(interval)
            memoryStyle = Defaults.sanitizedMenuBarMemoryStyle(memoryStyle)
            if TemperatureUnit(rawValue: temperatureUnit) == nil {
                temperatureUnit = TemperatureUnit.celsius.rawValue
            }
        }
    }
}

/// Drag-to-reorder list for the panel's major sections. Writes the new order to
/// `PanelLayout`, which the live panel observes. A bounded, non-scrolling list so
/// it sits inside the grouped Form without its own scroll area.
private struct PanelOrderEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.monitorShowFanControlBeta) private var showFanControlBeta = false
    @State private var order: [PanelSectionID] = PanelLayout.order
    @State private var dragging: PanelSectionID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(editableOrder) { id in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text(id.title(l10n.s))
                        Spacer()
                    }
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .opacity(dragging == id ? 0.45 : 1)
                    .onDrag {
                        dragging = id
                        return NSItemProvider(object: id.rawValue as NSString)
                    }
                    .onDrop(of: [UTType.text],
                            delegate: PanelOrderDropDelegate(target: id,
                                                             order: $order,
                                                             dragging: $dragging))

                    if id != editableOrder.last {
                        Divider()
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { order = PanelLayout.order }
        .onChange(of: showFanControlBeta) { _, _ in order = PanelLayout.order }
    }

    private var editableOrder: [PanelSectionID] {
        order.filter { $0 != .fanControl || showFanControlBeta }
    }
}

private struct PanelOrderDropDelegate: DropDelegate {
    let target: PanelSectionID
    @Binding var order: [PanelSectionID]
    @Binding var dragging: PanelSectionID?

    func dropEntered(info: DropInfo) {
        guard let dragging,
              dragging != target,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: target) else { return }

        withAnimation(.easeInOut(duration: 0.12)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        PanelLayout.setOrder(order)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        PanelLayout.setOrder(order)
        return true
    }
}
