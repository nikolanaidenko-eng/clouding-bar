import Foundation

/// A process's terminal ("/dev/ttys003"), read with sysctl: it tells a
/// terminal chat apart from every other, whatever its window is called.
enum Tty {
    static func of(pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil } // -1: no terminal
        return "/dev/" + String(cString: name)
    }

    /// A Codex program in a terminal: its tab, its folder, when it started.
    struct Program {
        let tty: String
        let pid: Int32
        let cwd: String
        let started: Date
    }

    /// The Codex programs in a terminal (its background helpers have none).
    static func codexPrograms() -> [Program] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))) // a count of pids
        var found: [Program] = []
        for pid in pids.prefix(max(0, min(n, pids.count))) where pid > 1 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { continue }
            let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix("codex"), let tty = of(pid: pid) else { continue }
            var path = proc_vnodepathinfo()
            let bytes = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &path, bytes) == bytes else { continue }
            let cwd = withUnsafePointer(to: &path.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let t = info.kp_proc.p_un.__p_starttime
            found.append(Program(tty: tty, pid: pid, cwd: cwd,
                                 started: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)))
        }
        return found
    }

    /// The path as the kernel gives a process's folder ("/private/tmp/x").
    static func real(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }
}
