import Foundation

/// A tiny unix-socket server. Claude Code hooks connect, write one JSON
/// payload, and hang up; we hand the complete payload to the handler.
/// Plain BSD sockets + DispatchSource — no dependencies.
final class HookSocketServer {
    private let path: String
    private let handler: (Data) -> Void
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "claudebar.socket")

    init(path: String, handler: @escaping (Data) -> Void) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        // A stale socket file from a previous run would make bind() fail.
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posixError("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw posixError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, size)
            }
        }
        guard bindResult == 0, listen(listenFD, 16) == 0 else {
            close(listenFD)
            throw posixError("bind/listen")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
    }

    private func acceptConnection() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        // Hooks send a small JSON blob and close, so a simple blocking
        // read-until-EOF on our own queue is plenty.
        queue.async { [weak self] in
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            close(fd)
            if !data.isEmpty {
                self?.handler(data)
            }
        }
    }

    private func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(String(cString: strerror(errno)))"])
    }

    deinit {
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}
