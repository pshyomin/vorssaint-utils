import Foundation

/// Pure state machine for the cleaning-mode unlock gesture: it counts consecutive
/// deliberate presses of a single key. Random wiping presses many different keys
/// at once, which keeps resetting the count, so it can't unlock by accident; a
/// person tapping one key in rhythm unlocks. Auto-repeat (holding a key) is
/// ignored so resting on a key can't unlock either, and a long pause restarts the
/// count. Extracted from the event tap so the logic can be tested deterministically.
struct CleaningUnlockCounter {
    let threshold: Int
    /// A same-key press only counts if it lands within this window of the previous
    /// one; a longer gap restarts the count.
    let pressWindow: TimeInterval

    private(set) var progress = 0
    private var lastKeyCode: Int64 = -1
    private var lastKeyTime: TimeInterval = -.greatestFiniteMagnitude

    init(threshold: Int, pressWindow: TimeInterval) {
        self.threshold = threshold
        self.pressWindow = pressWindow
    }

    /// Registers a key-down at `time` (a monotonic clock). `isRepeat` is true for
    /// auto-repeat events, which never count. Returns true once `progress` reaches
    /// the threshold, signalling the caller to unlock.
    mutating func registerKeyDown(code: Int64, time: TimeInterval, isRepeat: Bool) -> Bool {
        guard !isRepeat else { return false }
        if code == lastKeyCode, time - lastKeyTime <= pressWindow {
            progress += 1
        } else {
            progress = 1
        }
        lastKeyCode = code
        lastKeyTime = time
        return progress >= threshold
    }

    mutating func reset() {
        progress = 0
        lastKeyCode = -1
        lastKeyTime = -.greatestFiniteMagnitude
    }
}
