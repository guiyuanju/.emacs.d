import Darwin
import Foundation

/// An admin socket failure.
public struct AdminError: Error, CustomStringConvertible {
    public let description: String
}

/// One line the daemon writes on its admin socket (internal/admin.Response).
struct AdminResponse: Decodable {
    var status: Status?
    var error: String?
}

/// A connection to the daemon's admin socket, which speaks one JSON object per line each way.
/// Socket permissions (0600 in a 0700 directory) are the authentication.
public final class AdminConnection {
    private let fd: Int32
    private var buffer = Data()

    /// Connects to the socket at path.
    public init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdminError(description: "socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw AdminError(description: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw AdminError(description: "connect \(path): \(msg)")
        }
    }

    deinit { close(fd) }

    /// Shuts the connection down, so a read blocked on another thread returns.
    public func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

    /// Limits how long reads wait; nil waits forever.
    public func setReadTimeout(_ seconds: Double?) {
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        if let seconds {
            tv.tv_sec = Int(seconds)
            tv.tv_usec = Int32((seconds - Double(Int(seconds))) * 1_000_000)
        }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes one request line.
    public func send(_ request: [String: any Sendable]) throws {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AdminError(description: "write: \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
    }

    /// Reads the next status; an error response becomes an error.
    public func next() throws -> Status {
        let line = try readLine()
        let r: AdminResponse
        do {
            r = try JSONDecoder().decode(AdminResponse.self, from: line)
        } catch {
            throw AdminError(description: "bad response: \(error)")
        }
        if let e = r.error, !e.isEmpty { throw AdminError(description: e) }
        guard let st = r.status else { throw AdminError(description: "response without status") }
        return st
    }

    private func readLine() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw AdminError(description: "read: \(String(cString: strerror(errno)))")
            }
            if n == 0 { throw AdminError(description: "admin socket closed") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Sends request and reads its answer within 5 seconds.
    public func call(_ request: [String: any Sendable]) throws -> Status {
        setReadTimeout(5)
        defer { setReadTimeout(nil) }
        try send(request)
        return try next()
    }
}

/// Requests of the admin socket.
public enum Admin {
    /// Asks the daemon at path for its status.
    public static func status(path: String) throws -> Status {
        try AdminConnection(path: path).call(["op": "status"])
    }

    /// Turns keeping the Mac awake on or off and returns the new status.
    public static func setAwake(path: String, _ on: Bool) throws -> Status {
        try AdminConnection(path: path).call(["op": "set-awake", "on": on])
    }

    /// Quits Emacs and starts it again; returns the status once that is under way.
    public static func restartEmacs(path: String) throws -> Status {
        try AdminConnection(path: path).call(["op": "restart-emacs"])
    }

    /// Calls onStatus with each status the daemon at path pushes, until the connection fails.
    /// onConnect receives the connection so another thread can shut it down.
    public static func watch(
        path: String, onConnect: (AdminConnection) -> Void = { _ in }, onStatus: (Status) -> Void
    ) throws {
        let c = try AdminConnection(path: path)
        onConnect(c)
        try c.send(["op": "watch"])
        while true { onStatus(try c.next()) }
    }
}
