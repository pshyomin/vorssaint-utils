import Foundation

// Standalone unit tests for the pure metric helpers. Compiled with only
// MetricFormat.swift (no IOKit, no UI) by `./build.sh --test`, so they run fast
// and deterministically on any machine.
//
// A tiny @main harness instead of XCTest: the Command Line Tools cannot run
// `swift test`, and these checks need nothing more than equality assertions.
@main
struct MetricsTests {
    static func main() {
        var failures: [String] = []
        var checks = 0

        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            checks += 1
            if !condition { failures.append(message()) }
        }
        func expectEqual(_ actual: String, _ expected: String, _ label: String) {
            checks += 1
            if actual != expected { failures.append("\(label): got \"\(actual)\", expected \"\(expected)\"") }
        }
        func expectClose(_ actual: Double, _ expected: Double, _ label: String, tol: Double = 0.0001) {
            checks += 1
            if abs(actual - expected) > tol { failures.append("\(label): got \(actual), expected \(expected)") }
        }

        // MARK: Byte / rate formatting

        expectEqual(MetricFormat.bytes(0), "0 B", "bytes zero")
        expectEqual(MetricFormat.bytes(512), "512 B", "bytes < 1K")
        expectEqual(MetricFormat.bytes(1024), "1.0 KB", "bytes 1K")
        expectEqual(MetricFormat.bytes(1536), "1.5 KB", "bytes 1.5K")
        expectEqual(MetricFormat.bytes(10 * 1024), "10 KB", "bytes 10K drops decimal")
        expectEqual(MetricFormat.bytes(1024 * 1024), "1.0 MB", "bytes 1M")
        expectEqual(MetricFormat.bytes(3 * 1024 * 1024 * 1024), "3.0 GB", "bytes 3G")

        expectEqual(MetricFormat.bytesPerSec(0), "0 B/s", "rate zero")
        expectEqual(MetricFormat.bytesPerSec(2 * 1024 * 1024), "2.0 MB/s", "rate 2M")
        expectEqual(MetricFormat.bytesPerSec(1500 * 1024), "1.5 MB/s", "rate 1.5M")

        expectEqual(MetricFormat.bytesPerSecCompact(0), "0B", "compact zero")
        expectEqual(MetricFormat.bytesPerSecCompact(320 * 1024), "320K", "compact 320K")
        expectEqual(MetricFormat.bytesPerSecCompact(1.2 * 1024 * 1024), "1.2M", "compact 1.2M")

        // MARK: Watts & percent

        expectEqual(MetricFormat.watts(8.5), "8.5 W", "watts under 10")
        expectEqual(MetricFormat.watts(23.4), "23 W", "watts over 10 rounds")
        expectEqual(MetricFormat.wattsCompact(8.6), "9W", "watts compact rounds")
        expectEqual(MetricFormat.percent(0), "0%", "percent 0")
        expectEqual(MetricFormat.percent(0.125), "13%", "percent rounds")
        expectEqual(MetricFormat.percent(1), "100%", "percent full")
        expectEqual(MetricFormat.percent(1.4), "100%", "percent clamps high")
        expectEqual(MetricFormat.percent(-0.2), "0%", "percent clamps low")

        // MARK: Network speed math

        let slow = NetworkCounters(received: 1000, sent: 500)
        let fast = NetworkCounters(received: 1000 + 2048, sent: 500 + 1024)
        let speed = MetricFormat.netSpeed(previous: slow, current: fast, elapsed: 2)
        expectClose(speed.down, 1024, "down speed over 2s")
        expectClose(speed.up, 512, "up speed over 2s")

        let zeroElapsed = MetricFormat.netSpeed(previous: slow, current: fast, elapsed: 0)
        expect(zeroElapsed.down == 0 && zeroElapsed.up == 0, "zero elapsed yields zero")

        // Counter reset (interface went down) must not produce a negative/huge spike.
        let afterReset = MetricFormat.netSpeed(previous: fast, current: slow, elapsed: 2)
        expect(afterReset.down == 0 && afterReset.up == 0, "counter reset yields zero")

        // MARK: Interface filtering

        expect(MetricFormat.includeNetworkInterface("en0"), "en0 included")
        expect(MetricFormat.includeNetworkInterface("en12"), "en12 included")
        expect(!MetricFormat.includeNetworkInterface("lo0"), "lo0 excluded")
        expect(!MetricFormat.includeNetworkInterface("awdl0"), "awdl0 excluded")
        expect(!MetricFormat.includeNetworkInterface("utun3"), "utun3 (VPN) excluded")
        expect(!MetricFormat.includeNetworkInterface("bridge0"), "bridge0 excluded")
        expect(!MetricFormat.includeNetworkInterface(""), "empty excluded")

        // MARK: History ring buffer

        var history = MetricHistory(capacity: 3)
        history.push(1)
        history.push(2)
        expect(history.values == [1, 2], "history keeps order under capacity")
        history.push(3)
        history.push(4)
        expect(history.values == [2, 3, 4], "history drops oldest at capacity")
        expect(history.values.count == 3, "history never exceeds capacity")

        var single = MetricHistory(capacity: 1)
        single.push(5)
        single.push(6)
        expect(single.values == [6], "capacity 1 keeps only newest")

        // MARK: Cleaning-mode unlock gesture

        // Five deliberate taps of the same key unlock, on the fifth.
        var taps = CleaningUnlockCounter(threshold: 5, pressWindow: 2.0)
        var tapUnlock = false
        for (i, t) in [0.0, 0.3, 0.6, 0.9, 1.2].enumerated() {
            tapUnlock = taps.registerKeyDown(code: 0, time: t, isRepeat: false)
            if i < 4 { expect(!tapUnlock, "no unlock before the fifth tap (\(i + 1))") }
        }
        expect(tapUnlock, "five same-key taps unlock")
        expect(taps.progress == 5, "progress reaches the threshold")

        // Wiping the keyboard hits many different keys: it must never unlock.
        var wipe = CleaningUnlockCounter(threshold: 5, pressWindow: 2.0)
        var wipeUnlock = false
        for (i, code) in [Int64(10), 11, 12, 13, 14, 15, 16, 17].enumerated() {
            if wipe.registerKeyDown(code: code, time: Double(i) * 0.1, isRepeat: false) { wipeUnlock = true }
        }
        expect(!wipeUnlock, "wiping different keys never unlocks")
        expect(wipe.progress == 1, "different keys keep progress at 1")

        // A different key mid-streak resets the count.
        var streak = CleaningUnlockCounter(threshold: 5, pressWindow: 2.0)
        _ = streak.registerKeyDown(code: 9, time: 0.0, isRepeat: false)
        _ = streak.registerKeyDown(code: 9, time: 0.2, isRepeat: false)
        _ = streak.registerKeyDown(code: 9, time: 0.4, isRepeat: false)
        _ = streak.registerKeyDown(code: 8, time: 0.6, isRepeat: false)
        expect(streak.progress == 1, "a different key mid-streak resets to 1")

        // Auto-repeat (holding a key) is ignored, so resting on a key can't unlock.
        var held = CleaningUnlockCounter(threshold: 5, pressWindow: 2.0)
        var heldUnlock = false
        for i in 0..<10 {
            if held.registerKeyDown(code: 7, time: Double(i) * 0.1, isRepeat: true) { heldUnlock = true }
        }
        expect(!heldUnlock, "auto-repeat never unlocks")
        expect(held.progress == 0, "auto-repeat does not advance progress")

        // A pause longer than the window restarts the count.
        var paused = CleaningUnlockCounter(threshold: 5, pressWindow: 2.0)
        _ = paused.registerKeyDown(code: 3, time: 0.0, isRepeat: false)
        _ = paused.registerKeyDown(code: 3, time: 0.5, isRepeat: false)
        expect(paused.progress == 2, "presses within the window accumulate")
        _ = paused.registerKeyDown(code: 3, time: 10.0, isRepeat: false)
        expect(paused.progress == 1, "a pause beyond the window restarts the count")

        // reset() clears everything.
        var cleared = CleaningUnlockCounter(threshold: 5, pressWindow: 2.0)
        _ = cleared.registerKeyDown(code: 1, time: 0.0, isRepeat: false)
        _ = cleared.registerKeyDown(code: 1, time: 0.2, isRepeat: false)
        expect(cleared.progress == 2, "progress accumulates before reset")
        cleared.reset()
        expect(cleared.progress == 0, "reset clears progress")
        let afterReset2 = cleared.registerKeyDown(code: 1, time: 0.4, isRepeat: false)
        expect(!afterReset2 && cleared.progress == 1, "after reset the same key starts fresh at 1")

        // MARK: Result

        if failures.isEmpty {
            print("TESTS OK (\(checks) checks)")
            exit(0)
        } else {
            print("TESTS FAILED (\(failures.count) of \(checks)):")
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }
}
