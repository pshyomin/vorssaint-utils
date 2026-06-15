import SwiftUI

/// The "Network" card: live download/upload speed, a history graph and the
/// totals moved this session.
struct NetworkSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var speed = SpeedTest.shared
    @AppStorage(DefaultsKey.monitorGraphNetwork) private var showGraph = true
    @AppStorage(DefaultsKey.monitorNetSpeed) private var netSpeed = true
    @AppStorage(DefaultsKey.monitorNetTotals) private var netTotals = true
    @AppStorage(DefaultsKey.monitorNetTest) private var netTest = true

    var body: some View {
        Group {
            if visibleBlocks.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(l10n.s.networkSection)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(visibleBlocks.enumerated()), id: \.element) { index, block in
                            if index > 0 { Divider() }
                            blockContent(block)
                        }
                    }
                    .panelCard()
                }
            }
        }
    }

    private enum Block: Hashable { case speed, totals, test }

    private var visibleBlocks: [Block] {
        var blocks: [Block] = []
        if netSpeed { blocks.append(.speed) }
        if netTotals { blocks.append(.totals) }
        if netTest { blocks.append(.test) }
        return blocks
    }

    @ViewBuilder
    private func blockContent(_ block: Block) -> some View {
        switch block {
        case .speed: speedBlock
        case .totals: totalsRow
        case .test: speedTestRow
        }
    }

    private var speedBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                rateColumn(icon: "arrow.down",
                           label: l10n.s.networkDownload,
                           value: monitor.snapshot.netDownBytesPerSec,
                           color: .accentColor)
                Divider().frame(height: 28)
                rateColumn(icon: "arrow.up",
                           label: l10n.s.networkUpload,
                           value: monitor.snapshot.netUpBytesPerSec,
                           color: .green)
            }
            if showGraph, monitor.snapshot.netDownHistory.count >= 2 {
                graph
            }
        }
    }

    private func rateColumn(icon: String, label: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.map { MetricFormat.bytesPerSec($0) } ?? l10n.s.networkMeasuring)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Download (filled) and upload (line) share one scale so they compare fairly.
    private var graph: some View {
        let down = monitor.snapshot.netDownHistory
        let up = monitor.snapshot.netUpHistory
        let peak = max(down.max() ?? 0, up.max() ?? 0, 1)
        return ZStack {
            Sparkline(values: down, color: .accentColor, maxValue: peak)
            Sparkline(values: up, color: .green, maxValue: peak, fillOpacity: 0.08)
        }
        .frame(height: 30)
    }

    private var totalsRow: some View {
        HStack(spacing: 6) {
            Text(l10n.s.networkThisSession)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if let down = monitor.snapshot.netTotalDown, let up = monitor.snapshot.netTotalUp {
                Text("↓\(MetricFormat.bytes(down))  ↑\(MetricFormat.bytes(up))")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// On-demand internet speed test (latency, download, upload).
    private var speedTestRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if speed.isRunning {
                    ProgressView().controlSize(.small)
                    Text(l10n.s.speedTestTesting)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        speed.start()
                    } label: {
                        Label(speed.downloadMbps == nil ? l10n.s.speedTestRun : l10n.s.speedTestAgain,
                              systemImage: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                if let down = speed.downloadMbps, let up = speed.uploadMbps {
                    Text("↓\(mbps(down)) ↑\(mbps(up)) Mbps")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            if case .failed = speed.phase {
                Text(l10n.s.speedTestFailed)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if let latency = speed.latencyMs {
                Text("\(l10n.s.speedTestLatency): \(Int(latency.rounded())) ms")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func mbps(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
