import Foundation

/// A failed launchctl command.
public struct LaunchctlError: Error, CustomStringConvertible {
    public let args: [String]
    public let status: Int32
    public let output: String

    public var description: String {
        var msg = "launchctl \(args.joined(separator: " ")): exit status \(status)"
        if !output.isEmpty { msg += ": \(output)" }
        return msg
    }
}

/// A launchd job as launchctl print reports it.
public struct Service: Equatable, Sendable {
    public var loaded = false
    public var running = false
    public var pid = 0

    public init(loaded: Bool = false, running: Bool = false, pid: Int = 0) {
        self.loaded = loaded
        self.running = running
        self.pid = pid
    }
}

/// Runs launchctl(1) in the user's GUI domain.
public struct Launchctl: Sendable {
    /// Runs a command and returns its exit status and combined output.
    public typealias Runner = @Sendable (_ path: String, _ args: [String]) -> (status: Int32, output: String)

    public let path: String
    public let uid: uid_t
    let runner: Runner

    /// launchctl's exit status for a service that is not loaded.
    static let notFound: Int32 = 113

    public init(path: String, uid: uid_t = getuid(), runner: @escaping Runner = runProcess) {
        self.path = path
        self.uid = uid
        self.runner = runner
    }

    var domain: String { "gui/\(uid)" }

    func target(_ label: String) -> String { "\(domain)/\(label)" }

    @discardableResult
    func run(_ args: String...) throws -> String {
        let (status, output) = runner(path, args)
        guard status == 0 else {
            throw LaunchctlError(
                args: args, status: status, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    /// Whether label is loaded and running.
    public func service(_ label: String) throws -> Service {
        do {
            return parseService(try run("print", target(label)))
        } catch let e as LaunchctlError where e.status == Self.notFound || e.output.contains("Could not find service") {
            return Service()
        }
    }

    /// The labels launchctl print-disabled lists, true for those disabled.
    public func disabled() throws -> [String: Bool] {
        parseDisabled(try run("print-disabled", domain))
    }

    /// Loads plist into the GUI domain.
    public func bootstrap(_ plist: String) throws { try run("bootstrap", domain, plist) }

    /// Unloads label, stopping it.
    public func bootout(_ label: String) throws { try run("bootout", target(label)) }

    /// Starts label, killing a running instance first when kill is set.
    public func kickstart(_ label: String, kill: Bool) throws {
        if kill { try run("kickstart", "-k", target(label)) } else { try run("kickstart", target(label)) }
    }

    /// Makes sure label runs: kickstarts a loaded job and bootstraps plist otherwise.
    /// A disabled job is enabled just for the bootstrap, so starting by hand leaves Start at Login as it was.
    public func start(_ label: String, plist: String) throws {
        let svc = try service(label)
        if svc.running { return }
        if svc.loaded { return try kickstart(label, kill: false) }
        if try disabled()[label] == true {
            try run("enable", target(label))
            defer { _ = try? run("disable", target(label)) }
            return try bootstrap(plist)
        }
        try bootstrap(plist)
    }

    /// Whether none of labels is disabled, so launchd loads them all at login.
    public func loginEnabled(_ labels: [String]) throws -> Bool {
        let d = try disabled()
        return !labels.contains { d[$0] == true }
    }

    /// Enables or disables every label; launchd keeps the choice across logins.
    public func setLogin(_ on: Bool, _ labels: [String]) throws {
        var failures: [String] = []
        for label in labels {
            do { try run(on ? "enable" : "disable", target(label)) } catch { failures.append("\(error)") }
        }
        if !failures.isEmpty {
            throw LaunchctlError(args: ["start at login"], status: 1, output: failures.joined(separator: "; "))
        }
    }
}

/// The top-level state and pid of launchctl print's output.
public func parseService(_ out: String) -> Service {
    var s = Service(loaded: true)
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "state": s.running = parts[1] == "running"
        case "pid": s.pid = Int(parts[1]) ?? 0
        default: break
        }
    }
    return s
}

/// launchctl print-disabled's `"label" => disabled|enabled|true|false` lines.
public func parseDisabled(_ out: String) -> [String: Bool] {
    var m: [String: Bool] = [:]
    for line in out.split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " => ")
        guard parts.count == 2, parts[0].hasPrefix("\"") else { continue }
        m[parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))] =
            parts[1] == "disabled" || parts[1] == "true"
    }
    return m
}

/// Runs path with args, returning its exit status and combined output; a command that cannot start gives status 127.
@Sendable public func runProcess(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    if path.contains("/") {
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
    } else {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [path] + args
    }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
