import Foundation

// cloudingbar-hook — the Claude Code hook command (see docs/protocol.md).
//
// Every hook event goes through here: the JSON Claude Code pipes in is
// forwarded to the app's socket, plus the Claude process id and entrypoint.
// Two events can be answered from the bar, so for them we wait for a reply
// and print it as the hook's output:
//   - PermissionRequest                (Allow / Always / Deny)
//   - PreToolUse for AskUserQuestion   (pick an option or type an answer)
//
// The one rule: Claude must never get stuck because of us. Any trouble —
// the app isn't running, doesn't answer, hangs, crashes, sends garbage —
// ends in a silent exit 0 with no output. That is "no decision", and Claude
// carries on exactly as if this hook didn't exist (its own dialog shows).

signal(SIGPIPE, SIG_IGN)

/// Hard limits that hold whatever the app says.
let ackTimeout = 2.0       // the app must confirm a request this fast
let questionCap = 300.0    // longest a question is ever held
let permissionCap = 900.0  // longest a permission is ever held
// Last resort if something below blocks in a way we didn't foresee:
// SIGALRM's default action ends the process, which Claude treats as a
// hook error — a non-blocking one — and moves on.
alarm(UInt32(permissionCap + 30))

let started = Date()

func pass() -> Never { exit(0) }

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { pass() }

/// Claude's own pid: from the environment Claude Code gives its hooks, or
/// by walking up the process tree. The app uses it to tell when a session
/// is gone even if SessionEnd never arrived.
func claudePID() -> Int32? {
    if let s = ProcessInfo.processInfo.environment["CLAUDE_PID"], let pid = Int32(s), pid > 1 {
        return pid
    }
    var pid = getppid()
    for _ in 0..<6 where pid > 1 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        if name == "claude" || name == "codex" { return pid }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

if let pid = claudePID() { event["claude_pid"] = Int(pid) }
if let entry = ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"] {
    event["claude_entrypoint"] = entry
}
// Codex calls the same hook with --codex (~/.codex/hooks.json).
if CommandLine.arguments.contains("--codex") { event["claude_entrypoint"] = "codex" }
if let effort = ProcessInfo.processInfo.environment["CLAUDE_EFFORT"] {
    event["claude_effort"] = effort
}
// The git branch of its folder, and of the file it reads or changes. Read
// here, inside Claude Code, which already may read the project, so the app
// never has to ask macOS for Documents or Desktop.
if let cwd = event["cwd"] as? String, let branch = Git.branch(at: cwd) {
    event["git_branch"] = branch
}
if let input = event["tool_input"] as? [String: Any],
   let path = (input["file_path"] ?? input["notebook_path"]) as? String, path.hasPrefix("/"),
   let branch = Git.branch(at: (path as NSString).deletingLastPathComponent) {
    event["file_branch"] = branch
}

let eventName = event["hook_event_name"] as? String
let isPermission = eventName == "PermissionRequest"
let isQuestion = eventName == "PreToolUse" && (event["tool_name"] as? String) == "AskUserQuestion"
let cap = isPermission ? permissionCap : questionCap

// Compact JSON never contains a raw newline, so one line = one message.
guard var line = try? JSONSerialization.data(withJSONObject: event) else { pass() }
line.append(0x0A)

// MARK: - Socket

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cloudingbar/cloudingbar.sock").path

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { pass() }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
// Non-blocking: a hung app with a full backlog fails the connect instead
// of blocking it.
_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { pass() }
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { pass() }

/// Waits until fd is ready for `events`, or the deadline passes.
func wait(_ events: Int16, until deadline: Date) -> Bool {
    while true {
        let ms = Int32(max(0, min(deadline.timeIntervalSinceNow, 60)) * 1000)
        if ms <= 0 { return false }
        var p = pollfd(fd: fd, events: events, revents: 0)
        let r = poll(&p, 1, ms)
        if r > 0 { return true }
        if r < 0 && errno != EINTR { return false }
        if r == 0 && deadline.timeIntervalSinceNow <= 0 { return false }
    }
}

// Send. A big tool input (a whole file for Write) may take a few rounds.
let sendDeadline = Date().addingTimeInterval(ackTimeout)
var sent = 0
while sent < line.count {
    let n = line.withUnsafeBytes { write(fd, $0.baseAddress! + sent, line.count - sent) }
    if n > 0 { sent += n; continue }
    if n < 0 && (errno == EAGAIN || errno == EINTR), wait(Int16(POLLOUT), until: sendDeadline) { continue }
    pass()
}

guard isPermission || isQuestion else {
    close(fd)
    pass()
}

// MARK: - Wait for the answer
// The app replies with JSON lines:
//   {"hold": N}           keep waiting up to N more seconds (repeatable)
//   {"output": {...}}     final: print this as the hook output
//   {"pass": true}        final: no decision
// A closed socket, garbage, or silence past the deadline means "pass".

var deadline = started.addingTimeInterval(ackTimeout)
let hardDeadline = started.addingTimeInterval(cap)
var buffer = Data()
var chunk = [UInt8](repeating: 0, count: 4096)

while true {
    guard wait(Int16(POLLIN), until: min(deadline, hardDeadline)) else { pass() }
    let n = read(fd, &chunk, chunk.count)
    if n == 0 { pass() }
    if n < 0 {
        if errno == EAGAIN || errno == EINTR { continue }
        pass()
    }
    buffer.append(contentsOf: chunk[0..<n])
    if buffer.count > 1 << 20 { pass() }

    while let nl = buffer.firstIndex(of: 0x0A) {
        let message = buffer[buffer.startIndex..<nl]
        buffer = Data(buffer[buffer.index(after: nl)...])
        guard let obj = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] else { pass() }
        if let hold = (obj["hold"] as? NSNumber)?.doubleValue {
            // A couple of seconds' grace: the app's own timer should
            // fire first and say "pass" itself.
            deadline = Date().addingTimeInterval(max(0, hold) + 2)
            continue
        }
        guard let output = obj["output"] as? [String: Any],
              output["hookSpecificOutput"] is [String: Any],
              var text = try? JSONSerialization.data(withJSONObject: output) else { pass() }
        text.append(0x0A)
        FileHandle.standardOutput.write(text)
        exit(0)
    }
}
