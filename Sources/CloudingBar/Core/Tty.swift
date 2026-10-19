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
}
