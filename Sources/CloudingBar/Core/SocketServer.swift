import Foundation

/// The app's end of a request connection (a permission or a question).
/// Replies are JSON lines; see docs/protocol.md. Closing without a final
/// line means "no decision". `onClose` fires on the main queue if the hook
/// goes away first: Claude decided in its own UI, timed out, or quit.
final class Responder {
    var onClose: (() -> Void)?
    fileprivate weak var connection: Connection?

    fileprivate init(_ connection: Connection) { self.connection = connection }

    /// One with nowhere to answer (the checks).
    init() { connection = nil }

    /// Keep the hook waiting up to `seconds` more.
    func hold(_ seconds: Double) { connection?.send(["hold": seconds]) }

    /// Final answer: the JSON the hook prints for Claude.
    func answer(_ output: [String: Any]) { connection?.finish(["output": output]) }

    /// Final: no decision, Claude's own UI takes over.
    func pass() { connection?.finish(["pass": true]) }
}

/// Lets a Connection tell whether it is already on the server's queue.
private let socketQueueKey = DispatchSpecificKey<Bool>()

/// Unix socket server. Each connection carries one JSON message, ended by
/// a newline or by the sender closing. Requests stay open for the reply.
/// Plain BSD sockets + DispatchSource, no dependencies.
final class SocketServer {
    typealias Handler = (_ message: Inbound, _ responder: Responder?) -> Void

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    fileprivate let queue = DispatchQueue(label: "cloudingbar.socket")
    fileprivate var connections = Set<Connection>()

    /// `handler` runs on the main queue.
    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        queue.setSpecific(key: socketQueueKey, value: true)
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
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bindResult == 0, listen(listenFD, 64) == 0 else {
            close(listenFD)
            throw posixError("bind/listen")
        }
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
    }

    private func acceptConnection() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // Only your own processes: another user's can't ask or answer here.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: fd, server: self)
        connections.insert(connection)
        connection.start()
    }

    /// Called on `queue` once a connection's message is complete.
    fileprivate func received(_ data: Data, on connection: Connection, stillOpen: Bool) {
        guard let message = Inbound(data: data) else {
            connection.finish(nil)
            return
        }
        var responder: Responder?
        if message.isRequest && stillOpen {
            responder = Responder(connection)
            connection.responder = responder
        } else {
            connection.finish(nil)
        }
        DispatchQueue.main.async { [handler] in handler(message, responder) }
    }

    fileprivate func closed(_ connection: Connection) {
        connections.remove(connection)
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

/// One accepted connection. Everything here runs on the server's queue.
private final class Connection: Hashable {
    private let fd: Int32
    private unowned let server: SocketServer
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var gotMessage = false
    private var done = false
    /// Strong while waiting for an answer; the app holds it too.
    var responder: Responder?

    /// Senders write one message right away; anything slower is dropped.
    private static let messageTimeout: TimeInterval = 5
    private static let maxMessage = 16 << 20

    init(fd: Int32, server: SocketServer) {
        self.fd = fd
        self.server = server
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: server.queue)
        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
        server.queue.asyncAfter(deadline: .now() + Self.messageTimeout) { [weak self] in
            guard let self, !self.gotMessage else { return }
            self.finish(nil)
        }
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !done {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if gotMessage { continue } // nothing more is expected; ignore
                buffer.append(contentsOf: chunk[0..<n])
                if let nl = buffer.firstIndex(of: 0x0A) {
                    gotMessage = true
                    let message = buffer[buffer.startIndex..<nl]
                    buffer = Data()
                    server.received(Data(message), on: self, stillOpen: true)
                } else if buffer.count > Self.maxMessage {
                    finish(nil)
                }
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            // The other side closed (or the socket broke).
            if !gotMessage {
                gotMessage = true
                if !buffer.isEmpty {
                    let message = buffer
                    buffer = Data()
                    server.received(message, on: self, stillOpen: false)
                }
                finish(nil)
            } else {
                peerGone()
            }
            return
        }
    }

    private func peerGone() {
        guard !done else { return }
        let responder = self.responder
        finish(nil)
        if let responder {
            DispatchQueue.main.async { responder.onClose?() }
        }
    }

    func send(_ object: [String: Any]) {
        server.queue.async { self.write(object) }
    }

    func finish(_ object: [String: Any]?) {
        if DispatchQueue.getSpecific(key: socketQueueKey) == nil {
            server.queue.async { self.finish(object) }
            return
        }
        guard !done else { return }
        if let object { write(object) }
        done = true
        responder = nil
        source?.cancel()
        server.closed(self)
    }

    private func write(_ object: [String: Any]) {
        guard !done, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else { break } // full or broken: the hook falls back on its own
            }
        }
    }

    static func == (a: Connection, b: Connection) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
