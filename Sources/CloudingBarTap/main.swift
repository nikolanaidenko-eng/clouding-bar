import Foundation

// cloudingbar-tap — sits on Claude Code's stdout when the VS Code extension
// starts Claude through hooks/cloudingbar-wrapper.sh (and, with --input, on
// its stdin: Input.swift).
//
// The extension's panel never runs the status line command, but Claude Code
// tells the extension about the 5-hour limit on stdout (a stream-json
// "rate_limit_event" line). This copies stdin to stdout byte for byte and,
// on the side, forwards each of those lines to Clouding Bar's socket in the
// status line's shape. The copy always comes first: a missing or stuck
// Clouding Bar must never slow down or break Claude.

// Live until Claude closes the pipe, even if a signal hits the whole
// process group: Claude may still be writing its last lines. A vanished
// reader shows up as EPIPE instead of killing us.
for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { signal(sig, SIG_IGN) }

// On Claude's input instead (Input.swift): messages from Clouding Bar join in.
if CommandLine.arguments.dropFirst().first == "--input" { runInputRelay() }

let prefix = Array(#"{"type":"rate_limit_event""#.utf8)
let maxLine = 256 * 1024

enum LineState {
    case matching(Int)   // the line so far equals the first n bytes of prefix
    case capturing       // a rate_limit_event line; collecting it
    case skipping        // some other line; ignore until newline
}

var state = LineState.matching(0)
var line: [UInt8] = []

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cloudingbar/cloudingbar.sock").path

func writeAll(_ base: UnsafePointer<UInt8>, _ count: Int) -> Bool {
    var done = 0
    while done < count {
        let n = write(1, base + done, count - done)
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        done += n
    }
    return true
}

/// Turns a rate_limit_event into the status line JSON Clouding Bar already
/// understands: {"session_id", "rate_limits": {"five_hour": {...}, ...}}.
func report(_ bytes: [UInt8]) {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
          let info = obj["rate_limit_info"] as? [String: Any],
          let windows = info["unifiedWindows"] as? [String: Any] else { return }
    var limits: [String: Any] = [:]
    for key in ["five_hour", "seven_day"] {
        guard let w = windows[key] as? [String: Any],
              let utilization = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
        var out: [String: Any] = ["used_percentage": utilization * 100]
        if let resets = (w["resetsAt"] as? NSNumber)?.doubleValue { out["resets_at"] = resets }
        limits[key] = out
    }
    guard !limits.isEmpty else { return }
    var payload: [String: Any] = ["rate_limits": limits]
    if let sid = obj["session_id"] as? String { payload["session_id"] = sid }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    send(data)
}

/// One non-blocking shot at the socket; any hiccup just drops the update.
func send(_ data: Data) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var nosigpipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return }
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, data.count) }
}

/// Watches the byte stream for lines starting with the prefix.
func scan(_ base: UnsafePointer<UInt8>, _ count: Int) {
    var i = 0
    while i < count {
        switch state {
        case .skipping:
            // Jump straight to the end of the line.
            guard let nl = memchr(base + i, Int32(UInt8(ascii: "\n")), count - i) else { return }
            i = base.distance(to: nl.assumingMemoryBound(to: UInt8.self)) + 1
            state = .matching(0)

        case .matching(let n):
            let byte = base[i]
            i += 1
            if byte == UInt8(ascii: "\n") {
                state = .matching(0)
            } else if byte == prefix[n] {
                if n + 1 == prefix.count {
                    line = prefix
                    state = .capturing
                } else {
                    state = .matching(n + 1)
                }
            } else {
                state = .skipping
            }

        case .capturing:
            if let nl = memchr(base + i, Int32(UInt8(ascii: "\n")), count - i) {
                let end = base.distance(to: nl.assumingMemoryBound(to: UInt8.self))
                line.append(contentsOf: UnsafeBufferPointer(start: base + i, count: end - i))
                i = end + 1
                if line.count <= maxLine { report(line) }
                line = []
                state = .matching(0)
            } else {
                line.append(contentsOf: UnsafeBufferPointer(start: base + i, count: count - i))
                if line.count > maxLine { line = []; state = .skipping }
                return
            }
        }
    }
}

let bufferSize = 64 * 1024
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
while true {
    let n = read(0, buffer, bufferSize)
    if n == 0 { break }
    if n < 0 {
        if errno == EINTR { continue }
        break
    }
    guard writeAll(buffer, n) else { break }
    scan(buffer, n)
}
exit(0)
