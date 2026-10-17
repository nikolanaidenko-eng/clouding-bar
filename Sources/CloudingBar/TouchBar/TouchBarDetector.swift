import Foundation

/// Whether this Mac has a Touch Bar: its daemon, TouchBarServer, only runs
/// on Macs that have one. Read from the process table, no commands run.
enum TouchBarDetector {
    static var hasTouchBar: Bool { processRunning("TouchBarServer") }

    private static func processRunning(_ name: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }
        let found = size / MemoryLayout<kinfo_proc>.stride
        // p_comm keeps the first 16 characters of the process name.
        let wanted = String(name.prefix(Int(MAXCOMLEN)))
        for i in 0..<found {
            let comm = withUnsafePointer(to: &procs[i].kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            if comm == wanted { return true }
        }
        return false
    }
}
