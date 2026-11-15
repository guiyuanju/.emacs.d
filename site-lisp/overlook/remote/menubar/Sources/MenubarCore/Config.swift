import Foundation

/// Default launchd labels of the daemon and the menu bar app.
public let defaultDaemonLabel = "io.github.guiyuanju.overlook-remoted"
public let defaultLabel = "io.github.guiyuanju.overlook-menubar"

/// The menu bar app's configuration, read from Go-style flags so the LaunchAgent plist is the same as the daemon's tooling expects.
public struct Config: Equatable, Sendable {
    public var daemonLabel = defaultDaemonLabel
    public var daemonPlist = ""
    public var label = defaultLabel
    public var tokenFile = ""
    public var adminSocket = ""
    public var log = ""
    /// The page's port when the daemon cannot be asked; 0 leaves Copy URL off while it is stopped.
    public var port = 0
    public var launchctl = "/bin/launchctl"
    /// Only validate the flags and exit, for deploy.sh's smoke test.
    public var check = false
    /// -h or -help was given.
    public var help = false

    public init() {}

    public static let usage = """
        usage: overlook-menubar -token-file FILE [flags]
          -token-file FILE    the daemon's Bearer token file, for the page URL (required)
          -port N             the page's port when the daemon is stopped
          -admin-socket PATH  the daemon's admin socket (default <state dir>/overlook-remote/admin.sock)
          -daemon-label L     launchd label of overlook-remoted (default \(defaultDaemonLabel))
          -daemon-plist FILE  overlook-remoted's plist, bootstrapped when it is not loaded
                              (default ~/Library/LaunchAgents/<daemon-label>.plist)
          -label L            this app's own launchd label, for Start at Login (default \(defaultLabel))
          -log FILE           the daemon's log, for Open Log (default ~/Library/Logs/overlook-remoted.log)
          -launchctl CMD      launchctl command (default /bin/launchctl)
          -check              validate the flags and exit
        """

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Reads args (without the program name) the way Go's flag package does: -name value, -name=value, one or two dashes.
    public static func parse(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment)
        throws(ParseError) -> Config
    {
        let home = environment["HOME"] ?? NSHomeDirectory()
        var c = Config()
        var i = 0
        func value(_ name: String, _ inline: String?) throws(ParseError) -> String {
            if let inline { return inline }
            i += 1
            guard i < args.count else { throw ParseError("flag needs an argument: -\(name)") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                i += 1
                break
            }
            guard arg.hasPrefix("-"), arg != "-" else { break }
            var name = String(arg.drop(while: { $0 == "-" }))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            switch name {
            case "daemon-label": c.daemonLabel = try value(name, inline)
            case "daemon-plist": c.daemonPlist = try value(name, inline)
            case "label": c.label = try value(name, inline)
            case "token-file": c.tokenFile = try value(name, inline)
            case "admin-socket": c.adminSocket = try value(name, inline)
            case "log": c.log = try value(name, inline)
            case "launchctl": c.launchctl = try value(name, inline)
            case "port":
                let v = try value(name, inline)
                guard let p = Int(v) else { throw ParseError("invalid value \"\(v)\" for flag -port") }
                c.port = p
            case "check":
                guard inline == nil || inline == "true" || inline == "false" else {
                    throw ParseError("invalid boolean value for flag -check")
                }
                c.check = inline != "false"
            case "h", "help":
                c.help = true
                return c
            default:
                throw ParseError("flag provided but not defined: -\(name)")
            }
            i += 1
        }
        if i < args.count { throw ParseError("unexpected argument \"\(args[i])\"") }
        if c.daemonPlist.isEmpty { c.daemonPlist = "\(home)/Library/LaunchAgents/\(c.daemonLabel).plist" }
        if c.adminSocket.isEmpty { c.adminSocket = defaultAdminSocket(home: home, environment: environment) }
        if c.log.isEmpty { c.log = "\(home)/Library/Logs/overlook-remoted.log" }
        if c.tokenFile.isEmpty { throw ParseError("-token-file is required") }
        if !(0...65535).contains(c.port) { throw ParseError("-port \(c.port) is out of range") }
        return c
    }

    /// The daemon's default admin socket, beside its bridge socket (internal/config.DefaultSocket).
    public static func defaultAdminSocket(home: String, environment: [String: String]) -> String {
        let base = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/state"
        return "\(base)/overlook-remote/admin.sock"
    }
}
