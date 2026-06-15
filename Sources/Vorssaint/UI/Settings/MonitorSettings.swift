import SwiftUI

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
    @AppStorage(DefaultsKey.menuBarPower) private var menuBarPower = false
    @AppStorage(DefaultsKey.menuBarMemoryStyle) private var memoryStyle = "percent"
    @AppStorage(DefaultsKey.monitorInterval) private var interval = 2

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
            }
            Section(l10n.s.monitorPanelSection) {
                MonitorPanelConfig()
                Text(l10n.s.monitorPanelConfigHint)
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
    }
}
