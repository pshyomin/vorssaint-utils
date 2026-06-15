import Foundation

/// Cumulative interface byte counters (since boot), read from the kernel.
/// 64-bit so they never wrap on fast links — the reason totals stay accurate.
struct NetworkCounters: Equatable {
    var received: UInt64 = 0
    var sent: UInt64 = 0
}

/// Pure, deterministic helpers for the system monitor: number formatting, the
/// fixed-size history buffer, network speed math and interface filtering.
///
/// Everything here depends only on Foundation — no IOKit, no AppKit, no UI — so
/// it compiles and runs standalone in the unit-test target (`./build.sh --test`).
enum MetricFormat {
    // MARK: Byte sizes

    /// Splits a byte count into a human value + unit, base-1024.
    static func scale(_ bytes: Double) -> (value: Double, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return (value, units[index])
    }

    /// Bytes (raw) → "0", "8" for B; one decimal under 10, none at or above.
    private static func number(_ value: Double, unit: String) -> String {
        if unit == "B" { return String(format: "%.0f", value) }
        return value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    /// A whole quantity of bytes, e.g. "1.2 GB". Used for session totals.
    static func bytes(_ bytes: UInt64) -> String {
        let (value, unit) = scale(Double(bytes))
        return "\(number(value, unit: unit)) \(unit)"
    }

    /// A throughput, e.g. "1.2 MB/s". Used in the panel.
    static func bytesPerSec(_ bytesPerSecond: Double) -> String {
        let (value, unit) = scale(bytesPerSecond)
        return "\(number(value, unit: unit)) \(unit)/s"
    }

    /// A compact throughput for the menu bar, e.g. "1.2M", "320K", "0B".
    static func bytesPerSecCompact(_ bytesPerSecond: Double) -> String {
        let (value, unit) = scale(bytesPerSecond)
        let letter = unit == "B" ? "B" : String(unit.prefix(1))
        return "\(number(value, unit: unit))\(letter)"
    }

    // MARK: Watts & percentages

    /// Power, e.g. "8.5 W" / "23 W" (one decimal under 10, none above).
    static func watts(_ value: Double) -> String {
        let magnitude = abs(value)
        return magnitude < 10 ? String(format: "%.1f W", value) : String(format: "%.0f W", value)
    }

    /// Compact power for the menu bar, e.g. "9W".
    static func wattsCompact(_ value: Double) -> String {
        String(format: "%.0fW", value.rounded())
    }

    /// A 0...1 fraction as a rounded percentage, e.g. "12%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    // MARK: Network speed & filtering

    /// Per-second download/upload from two cumulative readings. Guards against a
    /// zero/negative interval and counter resets (interface down, rare wrap):
    /// a non-increasing counter yields 0 for that tick rather than a bogus spike.
    static func netSpeed(previous: NetworkCounters,
                         current: NetworkCounters,
                         elapsed: Double) -> (down: Double, up: Double) {
        guard elapsed > 0 else { return (0, 0) }
        let down = current.received >= previous.received
            ? Double(current.received - previous.received) / elapsed : 0
        let up = current.sent >= previous.sent
            ? Double(current.sent - previous.sent) / elapsed : 0
        return (down, up)
    }

    /// Whether an interface counts toward "real" network throughput. Loopback and
    /// virtual interfaces (AirDrop, VPN tunnels, bridges, etc.) are excluded so a
    /// VPN does not double-count the traffic already seen on the physical NIC.
    static func includeNetworkInterface(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let excluded = ["lo", "gif", "stf", "awdl", "llw", "utun", "bridge",
                        "ap", "anpi", "p2p", "XHC", "vmenet", "tap", "tun"]
        return !excluded.contains { name.hasPrefix($0) }
    }
}

/// Fixed-size ring of recent samples (oldest → newest) for the history graphs.
/// Appending past `capacity` drops the oldest values.
struct MetricHistory {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func push(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }
}
