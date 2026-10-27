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

    /// The Codex in a tab: its terminal and its process.
    struct Tab: Equatable {
        let tty: String
        let pid: Int32
    }

    /// The Codex chat files open right now, each with the tab of the Codex
    /// it's open in: Codex's helper writes the file and keeps it open while
    /// the chat is on; the helper's parent is the Codex in the tab. A file
    /// no one has open, or open under no tab (VS Code, the app): not here.
    static func codexFiles() -> [String: Tab] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))) // a count of pids
        var procs: [Int32: (name: String, parent: Int32)] = [:]
        for pid in pids.prefix(max(0, min(n, pids.count))) where pid > 1 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { continue }
            let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            procs[pid] = (name, info.kp_eproc.e_ppid)
        }
        var found: [String: Tab] = [:]
        var twice = Set<String>()
        for (pid, p) in procs where p.name.hasPrefix("codex") {
            for path in openFiles(pid) where path.hasSuffix(".jsonl") && (path as NSString).lastPathComponent.hasPrefix("rollout-") {
                // Up to the Codex that has a terminal: the one in the tab.
                var at = pid, tab: Tab?
                for _ in 0..<8 {
                    guard let q = procs[at], q.name.hasPrefix("codex") else { break }
                    if let tty = of(pid: at) { tab = Tab(tty: tty, pid: at); break }
                    at = q.parent
                }
                guard let tab else { continue }
                if let known = found[path], known != tab { twice.insert(path) }
                found[path] = tab
            }
        }
        for path in twice { found[path] = nil } // open under two tabs: neither
        return found
    }

    /// The files a process has open.
    private static func openFiles(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(min(fds.count, Int(got) / MemoryLayout<proc_fdinfo>.stride)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            paths.append(withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            })
        }
        return paths
    }

    /// The path as the kernel gives a process's folder ("/private/tmp/x").
    static func real(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }
}
