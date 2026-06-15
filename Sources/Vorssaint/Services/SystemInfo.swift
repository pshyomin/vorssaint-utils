import Darwin
import Foundation
import IOKit.ps

struct BatteryInfo {
    let percent: Int
    let isCharging: Bool
    let isOnBattery: Bool
}

/// Point-in-time system facts that need no special permissions.
/// The battery snapshot feeds the keep-awake battery protection; the memory
/// reading feeds the system monitor.
enum SystemInfo {
    static func batterySnapshot() -> BatteryInfo? {
        guard let blobRef = IOPSCopyPowerSourcesInfo() else { return nil }
        let blob = blobRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(blob) else { return nil }
        let list = listRef.takeRetainedValue() as [AnyObject]
        guard let first = list.first,
              let descRef = IOPSGetPowerSourceDescription(blob, first),
              let desc = descRef.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let current = desc["Current Capacity"] as? Int ?? 0
        let max = desc["Max Capacity"] as? Int ?? 100
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        let charging = desc["Is Charging"] as? Bool ?? false
        let state = desc["Power Source State"] as? String ?? ""
        return BatteryInfo(percent: percent,
                           isCharging: charging,
                           isOnBattery: state == "Battery Power")
    }

    static func memoryUsage() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        // mach_host_self() returns a send right the caller owns; release it or each
        // call leaks a mach port (this runs every couple of seconds while sampling).
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }
}
