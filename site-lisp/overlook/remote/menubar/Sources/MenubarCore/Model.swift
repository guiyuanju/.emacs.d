import Foundation

/// The daemon's status as its admin socket reports it (internal/admin.Status); fields the menu does not use are left out.
public struct Status: Codable, Equatable, Sendable {
    public var daemon = ""
    public var emacs = ""
    public var streams = 0
    /// The keep-awake setting; awakeHeld is whether caffeinate runs now.
    public var awake = false
    public var awakeHeld = false
    /// scheme, host and port make the page URL a phone opens; host is "" when no address fits.
    public var scheme = ""
    public var host = ""
    public var port = 0

    public init(
        daemon: String = "", emacs: String = "", streams: Int = 0, awake: Bool = false, awakeHeld: Bool = false,
        scheme: String = "", host: String = "", port: Int = 0
    ) {
        self.daemon = daemon
        self.emacs = emacs
        self.streams = streams
        self.awake = awake
        self.awakeHeld = awakeHeld
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemon = try c.decodeIfPresent(String.self, forKey: .daemon) ?? ""
        emacs = try c.decodeIfPresent(String.self, forKey: .emacs) ?? ""
        streams = try c.decodeIfPresent(Int.self, forKey: .streams) ?? 0
        awake = try c.decodeIfPresent(Bool.self, forKey: .awake) ?? false
        awakeHeld = try c.decodeIfPresent(Bool.self, forKey: .awakeHeld) ?? false
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
    }
}

/// What the icon shows.
public enum IconState: Sendable {
    case stopped, emacsOffline, online
}

/// What the menu shows for a status.
public struct Menu: Equatable, Sendable {
    public var state: IconState
    public var status: String
    /// The Keep Mac Awake check mark, and whether it can be toggled.
    public var awake = false
    public var awakeEnabled = false
    public var awakeTitle = "Keep Mac Awake"
    /// The title of the start/restart item.
    public var restart: String

    /// The menu for st; nil means the daemon cannot be reached.
    public init(_ st: Status?) {
        guard let st else {
            state = .stopped
            status = "Remote stopped"
            restart = "Start Remote"
            return
        }
        state = st.emacs == "online" ? .online : .emacsOffline
        status = st.emacs == "online" ? "Remote online" : "Emacs not connected"
        switch st.streams {
        case 0: status += " · no pages open"
        case 1: status += " · 1 page open"
        default: status += " · \(st.streams) pages open"
        }
        awake = st.awake
        awakeEnabled = true
        if st.awake && !st.awakeHeld { awakeTitle = "Keep Mac Awake (caffeinate not running)" }
        restart = "Restart Remote"
    }
}

public struct RemoteError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

/// The page's address with its token; an empty host becomes localhost and an IPv6 host gets brackets.
public func pageURL(scheme: String, host: String, port: Int, token: String) -> String {
    var h = host.isEmpty ? "localhost" : host
    if h.contains(":") { h = "[\(h)]" }
    return "\(scheme.isEmpty ? "http" : scheme)://\(h):\(port)/overlook/#\(token)"
}

/// The page address for st, or, when the daemon cannot be reached (st nil), for port on this machine's preferred address.
public func remoteURL(_ st: Status?, port: Int, tokenFile: String, host: () -> String = preferredHost) throws -> String
{
    let token = try readToken(tokenFile)
    if let st, st.port != 0 {
        return pageURL(scheme: st.scheme, host: st.host, port: st.port, token: token)
    }
    guard port != 0 else { throw RemoteError(description: "the page's port is unknown while Remote is stopped") }
    return pageURL(scheme: "http", host: host(), port: port, token: token)
}

/// Reads the token file, which Emacs and the daemon share.
public func readToken(_ path: String) throws -> String {
    let token: String
    do {
        token = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw RemoteError(description: "cannot read \(path)")
    }
    guard !token.isEmpty else { throw RemoteError(description: "\(path) is empty") }
    return token
}
