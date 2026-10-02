import Foundation
import Darwin

struct Proc {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let start: Date
    let path: String
    /// phys_footprint — the "Memory" column in Activity Monitor and `top`, including compressed and swapped pages.
    let footprint: UInt64
}

/// A pid plus its start time, so a later kill can't hit a different process that reused the pid.
struct PidRef {
    let pid: pid_t
    let start: Date
}

/// Reads the process table with libproc/sysctl. Not thread-safe: Model only touches it from its serial queue.
final class ProcessScanner: @unchecked Sendable {  // confined to Model's serial scan queue
    private struct Key: Hashable { let pid: pid_t; let start: Int }
    private var pathCache: [Key: String] = [:]
    private var argsCache: [Key: [String]] = [:]
    private var argBuffer: [UInt8]
    private let myUID = getuid()

    init() {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&mib, 2, &argmax, &size, nil, 0) != 0 || argmax <= 0 { argmax = 1 << 20 }
        argBuffer = [UInt8](repeating: 0, count: Int(argmax))
    }

    func scan() -> [pid_t: Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        size = list.count * stride
        guard sysctl(&mib, 3, &list, &size, nil, 0) == 0 else { return [:] }

        var result: [pid_t: Proc] = [:]
        var live = Set<Key>()
        for kp in list.prefix(size / stride) {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            let tv = kp.kp_proc.p_un.__p_starttime
            let key = Key(pid: pid, start: Int(tv.tv_sec))
            live.insert(key)

            let path: String
            if let cached = pathCache[key] {
                path = cached
            } else {
                path = Self.execPath(pid) ?? withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                pathCache[key] = path
            }
            let uid = kp.kp_eproc.e_ucred.cr_uid
            result[pid] = Proc(
                pid: pid,
                ppid: kp.kp_eproc.e_ppid,
                uid: uid,
                start: Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6),
                path: path,
                footprint: uid == myUID ? Self.footprint(pid) : 0
            )
        }
        pathCache = pathCache.filter { live.contains($0.key) }
        argsCache = argsCache.filter { live.contains($0.key) }
        return result
    }

    func arguments(_ p: Proc) -> [String] {
        let key = Key(pid: p.pid, start: Int(p.start.timeIntervalSince1970))
        if let cached = argsCache[key] { return cached }
        let args = readArguments(p.pid)
        argsCache[key] = args
        return args
    }

    func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Sends SIGTERM only if the pid still belongs to the same process we scanned.
    @discardableResult
    static func terminate(_ ref: PidRef) -> Bool {
        guard ref.pid > 1, ref.pid != getpid() else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(ref.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              Int(info.pbi_start_tvsec) == Int(ref.start.timeIntervalSince1970),
              info.pbi_uid == getuid()
        else { return false }
        return kill(ref.pid, SIGTERM) == 0
    }

    private static func execPath(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return nil }
        return String(decoding: buf.prefix(Int(len)), as: UTF8.self)
    }

    private static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return r == 0 ? info.ri_phys_footprint : 0
    }

    /// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated strings.
    private func readArguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argBuffer.count
        guard sysctl(&mib, 3, &argBuffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = argBuffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && argBuffer[i] != 0 { i += 1 }
        while i < size && argBuffer[i] == 0 { i += 1 }
        var args: [String] = []
        var start = i
        while i < size && args.count < argc {
            if argBuffer[i] == 0 {
                args.append(String(decoding: argBuffer[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }
}
