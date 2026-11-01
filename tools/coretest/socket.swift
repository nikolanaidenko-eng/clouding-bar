import Foundation

// The socket from both ends: the server the app runs, a plain client, and the
// real hook and tap programs talking to it. All in a folder of the checks' own.

/// A blocking client, as the hook is.
private func connectTo(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { close(fd); return nil }
    return fd
}

private func say(_ fd: Int32, _ text: String) { _ = text.withCString { write(fd, $0, strlen($0)) } }

/// What the server says until a newline or its close; the main queue keeps going meanwhile.
private func hear(_ fd: Int32, timeout: TimeInterval = 3) -> (line: String?, closed: Bool) {
    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 1024)
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, 5) > 0 {
            // One byte at a time past the newline stays for the next call.
            let n = read(fd, &chunk, 1)
            if n <= 0 { return (buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self), true) }
            if chunk[0] == 0x0A { return (String(decoding: buffer, as: UTF8.self), false) }
            buffer.append(chunk[0])
        } else {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    return (nil, false)
}

private func json(_ line: String?) -> [String: Any]? {
    line.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
}

/// A program run with these lines fed one at a time; the main queue keeps going.
private func run(_ path: String, args: [String] = [], env: [String: String], feed: [Data], gap: TimeInterval = 0) -> (out: Data, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (Data(), -1) }
    var out = Data()
    let reader = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        out = output.fileHandleForReading.readDataToEndOfFile()
        reader.signal()
    }
    for (i, piece) in feed.enumerated() {
        input.fileHandleForWriting.write(piece)
        if i < feed.count - 1, gap > 0 { RunLoop.main.run(until: Date().addingTimeInterval(gap)) }
    }
    try? input.fileHandleForWriting.close()
    spin(20) { !p.isRunning }
    if p.isRunning { p.terminate() }
    while reader.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    p.waitUntilExit()
    return (out, p.terminationStatus)
}

func runSocketChecks() {
    withShortFolder("sock") { dir in
        let path = dir.appendingPathComponent("s.sock").path

        // MARK: Starting

        let tooLong = SocketServer(path: dir.path + "/" + String(repeating: "x", count: 200)) { _, _ in }
        check((try? tooLong.start()) == nil, "server: a path too long for a socket: an error, not a crash")
        try? "left over".write(toFile: path, atomically: true, encoding: .utf8)
        var received: [(message: Inbound, responder: Responder?)] = []
        var server: SocketServer? = SocketServer(path: path) { received.append(($0, $1)) }
        check((try? server?.start()) != nil, "server: a stale file from a previous run doesn't stop it")
        let mode = ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600, "server: only you may connect")

        func next() -> (message: Inbound, responder: Responder?)? {
            let count = received.count
            spin(3) { received.count > count }
            return received.count > count ? received[count] : nil
        }

        // MARK: One message

        if let c = connectTo(path) {
            say(c, #"{"hook_event_name":"Stop","session_id":"a"}"# + "\n")
            let got = next()
            check(got?.message.sessionId == "a" && got?.responder == nil, "server: a message on its line, on the main queue; nothing to answer")
            check(hear(c).closed, "server: and the connection closes, nobody waits on it")
            close(c)
        }
        if let c = connectTo(path) {
            say(c, #"{"session_id":"no-newline"}"#)
            shutdown(c, SHUT_WR)
            check(next()?.message.sessionId == "no-newline", "server: ended by the sender closing, it counts too")
            close(c)
        }
        if let c = connectTo(path) {
            say(c, #"{"hook_event_name":"PermissionRequest","session_id":"late"}"#)
            shutdown(c, SHUT_WR)
            check(next()?.responder == nil, "server: a request whose sender has left has nowhere to answer")
            close(c)
        }
        if let c = connectTo(path) {
            let count = received.count
            say(c, "not json\n")
            check(hear(c).closed && received.count == count, "server: garbage: closed, no one told")
            close(c)
        }
        if let c = connectTo(path) {
            say(c, #"{"session_id":"#)
            let chunk = String(repeating: "x", count: 1 << 20)
            for _ in 0..<17 { say(c, chunk) }
            let count = received.count
            check(hear(c, timeout: 5).closed && received.count == count, "server: a message over 16 MB: dropped")
            close(c)
        }
        if let c = connectTo(path) {
            let count = received.count
            check(hear(c, timeout: 6).closed && received.count == count, "server: a sender who says nothing: dropped after 5 s")
            close(c)
        }

        // MARK: A request

        if let c = connectTo(path) {
            say(c, #"{"hook_event_name":"PermissionRequest","session_id":"p"}"# + "\n")
            let responder = next()?.responder
            check(responder != nil, "request: it can be answered")
            responder?.hold(30)
            check(json(hear(c).line)?["hold"] as? Double == 30, "request: keep waiting")
            responder?.hold(20)
            check(json(hear(c).line)?["hold"] as? Double == 20, "request: and again")
            responder?.answer(["hookSpecificOutput": ["x": 1]])
            let answer = hear(c)
            check((json(answer.line)?["output"] as? [String: Any])?["hookSpecificOutput"] != nil, "request: the answer")
            check(hear(c).closed, "request: and it's over")
            responder?.answer(["again": true])
            responder?.pass()
            check(true, "request: answered twice: nothing more, no crash")
            close(c)
        }
        if let c = connectTo(path) {
            say(c, #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","session_id":"q"}"# + "\n")
            next()?.responder?.pass()
            check(json(hear(c).line)?["pass"] as? Bool == true, "request: no decision: Claude's own UI takes over")
            close(c)
        }
        if let c = connectTo(path) {
            say(c, #"{"hook_event_name":"PermissionRequest","session_id":"gone"}"# + "\n")
            let responder = next()?.responder
            var closed = false
            responder?.onClose = { closed = true }
            close(c)
            check(spin(3) { closed }, "request: its hook gone (Claude decided, or quit): the app is told")
            responder?.answer(["late": true])
            check(true, "request: answered after that: nothing, no crash")
        }
        if let c = connectTo(path) {
            say(c, #"{"hook_event_name":"PermissionRequest","session_id":"more"}"# + "\n" + "more after the line")
            let responder = next()?.responder
            check(responder != nil, "request: what comes after its line is ignored")
            responder?.pass()
            close(c)
        }

        // MARK: The real hook

        let hook = helperBinaries + "/cloudingbar-hook"
        let hookEnv = ["CLOUDINGBAR_DIR": dir.path]
        let sock = dir.appendingPathComponent("cloudingbar.sock").path
        var answer: (Responder) -> Void = { $0.pass() }
        var events: [Inbound] = []
        let app = SocketServer(path: sock) { message, responder in
            events.append(message)
            if let responder { answer(responder) }
        }
        check((try? app.start()) != nil, "hook: the app's socket")
        func fire(_ event: [String: Any], args: [String] = [], env: [String: String] = [:]) -> (out: String, status: Int32) {
            let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
            let r = run(hook, args: args, env: hookEnv.merging(env) { $1 }, feed: [data])
            return (String(decoding: r.out, as: UTF8.self), r.status)
        }

        let forwarded = fire(["hook_event_name": "Stop", "session_id": "h1"],
                             env: ["CLAUDE_PID": String(getpid()), "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_EFFORT": "high"])
        check(forwarded.out.isEmpty && forwarded.status == 0, "hook: an event goes on its way, nothing printed")
        check(spin(3) { !events.isEmpty } && events.last?.claudePid == getpid() && events.last?.entrypoint == "cli" && events.last?.effort == "high",
              "hook: with its Claude's pid, where it runs and its effort")
        let noPid = fire(["hook_event_name": "Stop", "session_id": "h2"], env: ["CLAUDE_PID": "1", "CLAUDE_CODE_ENTRYPOINT": ""])
        check(noPid.status == 0 && spin(3) { events.last?.sessionId == "h2" } && events.last?.claudePid != 1, "hook: pid 1 is nobody's Claude")
        _ = fire(["hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "h3"], args: ["--codex"])
        check(spin(3) { events.last?.sessionId == "h3" } && events.last?.entrypoint == "codex", "hook: for Codex, marked")

        let repo = dir.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try? "ref: refs/heads/hook-branch\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        _ = fire(["hook_event_name": "PreToolUse", "tool_name": "Edit", "session_id": "h4", "cwd": repo.path, "tool_input": ["file_path": repo.path + "/f.txt"]])
        check(spin(3) { events.last?.sessionId == "h4" } && events.last?.gitBranch == "hook-branch" && events.last?.fileBranch == "hook-branch",
              "hook: the branch of its folder and of its file, read there")

        let allow: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        answer = { $0.answer(allow) }
        let allowed = fire(["hook_event_name": "PermissionRequest", "session_id": "h5", "tool_name": "Bash"])
        check((json(allowed.out)?["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String == "PermissionRequest" && allowed.status == 0,
              "hook: a permission's answer printed for Claude")
        answer = { $0.pass() }
        check(fire(["hook_event_name": "PermissionRequest", "session_id": "h6", "tool_name": "Bash"]).out.isEmpty, "hook: no decision: nothing printed")
        answer = { r in
            r.hold(5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { r.answer(allow) }
        }
        check(!fire(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "session_id": "h7"]).out.isEmpty, "hook: held, then answered")
        answer = { r in r.answer(["not": "what Claude wants"]) }
        check(fire(["hook_event_name": "PermissionRequest", "session_id": "h8"]).out.isEmpty, "hook: an answer not of the shape Claude takes: nothing printed")

        // An app that never answers, or isn't there.
        answer = { _ in }
        let began = Date()
        check(fire(["hook_event_name": "PermissionRequest", "session_id": "h9"]).out.isEmpty && Date().timeIntervalSince(began) < 5,
              "hook: the app silent: gives up within seconds, Claude isn't kept waiting")
        check(run(hook, env: hookEnv, feed: [Data("not json".utf8)]).out.isEmpty, "hook: what it's given isn't JSON: nothing")
        check(run(hook, env: ["CLOUDINGBAR_DIR": dir.appendingPathComponent("no-app").path], feed: [Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8)]).status == 0,
              "hook: no app: it steps aside")

        // MARK: Gone

        server = nil
        check(!FileManager.default.fileExists(atPath: path), "server: gone, its socket goes too")
        withExtendedLifetime(app) {}
    }
}

func runHelperChecks() {
    // MARK: The real tap, on the copy of Claude's output it watches

    withShortFolder("tap") { home in
        let folder = home.appendingPathComponent(".cloudingbar")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sock = folder.appendingPathComponent("cloudingbar.sock").path
        var heard: [Inbound] = []
        let app = SocketServer(path: sock) { message, _ in heard.append(message) }
        guard (try? app.start()) != nil else { check(false, "tap: the app's socket"); return }
        let tap = helperBinaries + "/cloudingbar-tap"
        // Its folder is the home one's: never the real app's socket.
        let env = ["CFFIXED_USER_HOME": home.path]

        let limit = #"{"type":"rate_limit_event","session_id":"t1","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.52,"resetsAt":1234},"seven_day":{"utilization":0.1}}}}"# + "\n"
        let other = #"{"type":"assistant","message":{"content":"rate_limit_event"}}"# + "\n"
        let piped = run(tap, env: env, feed: [Data((other + limit + other).utf8)])
        check(piped.out == Data((other + limit + other).utf8) && piped.status == 0, "tap: everything through, byte for byte")
        check(spin(3) { !heard.isEmpty }, "tap: a limit's line goes to the app")
        check(heard.first?.fiveHour?.used.map { abs($0 - 52) < 0.001 } == true && heard.first?.fiveHour?.resetsAt == 1234
              && heard.first?.sevenDay?.used.map { abs($0 - 10) < 0.001 } == true && heard.first?.sessionId == "t1", "tap: in the status line's shape, percent from a share")

        heard = []
        let cut = limit.utf8.count / 2
        let bytes = Array(limit.utf8)
        let split = run(tap, env: env, feed: [Data(bytes[..<10]), Data(bytes[10..<cut]), Data(bytes[cut...])], gap: 0.05)
        check(split.out == Data(bytes), "tap: a line in pieces still through")
        check(spin(3) { !heard.isEmpty } && heard.first?.sessionId == "t1", "tap: and still read, wherever it was cut")

        heard = []
        let quiet = [
            #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{}}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{}}"#,
            #"{"type":"rate_limit_event", not json"#,
            #"{"type":"rate_limit_event"}"#,
            #"{"type":"rate_limit_events_are_not_this"}"#,
        ].joined(separator: "\n") + "\n"
        let unread = run(tap, env: env, feed: [Data(quiet.utf8)])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(unread.out == Data(quiet.utf8) && heard.isEmpty, "tap: nothing it can read goes on, all of it passes")

        let huge = #"{"type":"rate_limit_event","x":""# + String(repeating: "y", count: 300 * 1024) + "\"}\n"
        let big = run(tap, env: env, feed: [Data((huge + limit).utf8)])
        check(big.out == Data((huge + limit).utf8), "tap: a line past its limit passes too")
        check(spin(3) { !heard.isEmpty } && heard.count == 1 && heard[0].sessionId == "t1", "tap: not read itself, and the next one still is")
        heard = []
        let last = String(limit.dropLast())
        check(run(tap, env: env, feed: [Data(last.utf8)]).out == Data(last.utf8), "tap: a last line with no end: through")
        check(run(tap, env: env, feed: []).out.isEmpty, "tap: nothing in, nothing out")
        withExtendedLifetime(app) {}
    }

    // MARK: Nobody home

    withShortFolder("tap2") { home in
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5}}}}"# + "\n"
        let alone = run(helperBinaries + "/cloudingbar-tap", env: ["CFFIXED_USER_HOME": home.path], feed: [Data(line.utf8)])
        check(alone.out == Data(line.utf8) && alone.status == 0, "tap: the app not running: Claude's output still through")
    }

    // MARK: The relay's door

    withShortFolder("door") { dir in
        withAppFolder(dir) {
            check(Inject.send(Data("{}".utf8), pid: 999_999) == false, "inject: no door there: not sent")
            let tooDeep = dir.path + "/" + String(repeating: "d", count: 150)
            withAppFolder(URL(fileURLWithPath: tooDeep)) {
                check(Inject.send(Data("{}".utf8), pid: getpid()) == false, "inject: a path too long for a socket: not sent, no crash")
            }
            check(Inject.message("", files: []) == nil, "inject: nothing to send")
        }
    }
}
