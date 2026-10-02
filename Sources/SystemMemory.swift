import Foundation
import Darwin

/// System-wide memory numbers, read the same way Activity Monitor and `memory_pressure` do.
struct SystemMemory {
    var total: UInt64 = 0
    /// App memory + wired + compressed (Activity Monitor's "Memory Used").
    var used: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// kern.memorystatus_level — the "System-wide memory free percentage" from `memory_pressure`.
    var freePercent: Int = 100
    /// kern.memorystatus_vm_pressure_level — 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int = 1

    private static let host = mach_host_self()

    static func read() -> SystemMemory {
        var m = SystemMemory()
        m.total = ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(pageSize)
            let anonymous = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            let app = anonymous > purgeable ? anonymous - purgeable : 0
            m.used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }
        if let level = sysctlInt("kern.memorystatus_level") { m.freePercent = level }
        if let pressure = sysctlInt("kern.memorystatus_vm_pressure_level") { m.pressureLevel = pressure }
        return m
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}
