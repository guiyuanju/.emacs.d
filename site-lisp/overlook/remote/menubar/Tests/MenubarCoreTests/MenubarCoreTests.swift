import CoreImage
import Foundation
import Testing

@testable import MenubarCore

@Suite struct ConfigTests {
    let env = ["HOME": "/Users/u"]

    @Test func defaults() throws {
        let c = try Config.parse(["-token-file", "/t", "-port", "8766"], environment: env)
        #expect(c.daemonLabel == defaultDaemonLabel)
        #expect(c.label == defaultLabel)
        #expect(c.port == 8766)
        #expect(c.daemonPlist == "/Users/u/Library/LaunchAgents/\(defaultDaemonLabel).plist")
        #expect(c.adminSocket == "/Users/u/.local/state/overlook-remote/admin.sock")
        #expect(c.log == "/Users/u/Library/Logs/overlook-remoted.log")
        #expect(!c.check)
    }

    @Test func goFlagForms() throws {
        let c = try Config.parse(
            ["--token-file=/t", "-daemon-label", "x.d", "-check", "-admin-socket=/a.sock"], environment: env)
        #expect(c.tokenFile == "/t")
        #expect(c.daemonPlist == "/Users/u/Library/LaunchAgents/x.d.plist")
        #expect(c.check)
        #expect(c.adminSocket == "/a.sock")
        let x = try Config.parse(["-token-file", "/t"], environment: ["HOME": "/h", "XDG_RUNTIME_DIR": "/run/u"])
        #expect(x.adminSocket == "/run/u/overlook-remote/admin.sock")
        #expect(try Config.parse(["-h"], environment: env).help)
    }

    @Test(arguments: [
        [], ["-token-file", "t", "-port", "70000"], ["-token-file", "t", "extra"], ["-token-file"],
        ["-token-file", "t", "-nope"], ["-token-file", "t", "-port", "x"],
    ])
    func rejects(_ args: [String]) {
        #expect(throws: Config.ParseError.self) { try Config.parse(args, environment: env) }
    }
}

@Suite struct ModelTests {
    @Test func menus() {
        #expect(Menu(nil) == Menu(nil))
        let stopped = Menu(nil)
        #expect(stopped.state == .stopped && stopped.status == "Remote stopped" && stopped.restart == "Start Remote")
        #expect(!stopped.awakeEnabled)

        let online = Menu(Status(emacs: "online", streams: 2, awake: true, awakeHeld: true))
        #expect(online.state == .online && online.status == "Remote online · 2 pages open")
        #expect(online.awake && online.awakeEnabled && online.awakeTitle == "Keep Mac Awake")
        #expect(online.restart == "Restart Remote")

        let offline = Menu(Status(emacs: "offline", streams: 1))
        #expect(offline.state == .emacsOffline && offline.status == "Emacs not connected · 1 page open")
        #expect(!offline.awake && offline.awakeEnabled)

        let unheld = Menu(Status(emacs: "online", awake: true))
        #expect(unheld.status == "Remote online · no pages open")
        #expect(unheld.awakeTitle == "Keep Mac Awake (caffeinate not running)")
        #expect(unheld.emacsRestart == nil)
    }

    @Test func emacsMenus() throws {
        let stuck = Menu(Status(emacs: "online", emacsState: "unresponsive", emacsCanRestart: true))
        #expect(stuck.status == "Emacs not responding · no pages open")
        #expect(stuck.emacsRestart == "Restart Emacs" && stuck.emacsRestartEnabled && stuck.emacsRestartConfirm)
        let restarting = Menu(Status(emacs: "offline", emacsState: "restarting", emacsCanRestart: true))
        #expect(restarting.status.hasPrefix("Restarting Emacs…") && !restarting.emacsRestartEnabled)
        let crashed = Menu(Status(emacs: "offline", emacsState: "crashed", emacsCanRestart: true))
        #expect(crashed.emacsRestart == "Start Emacs" && !crashed.emacsRestartConfirm)
        #expect(Menu(Status(emacs: "online", emacsState: "online")).emacsRestart == nil)

        let json = #"{"emacs":"online","emacsProcess":{"state":"crashed","canRestart":true,"error":"too many"}}"#
        let st = try JSONDecoder().decode(Status.self, from: Data(json.utf8))
        #expect(st.emacsState == "crashed" && st.emacsCanRestart && st.emacsError == "too many")
        let back = try JSONDecoder().decode(Status.self, from: try JSONEncoder().encode(st))
        #expect(back == st)
    }

    @Test func decodesTheDaemonsStatus() throws {
        let json = """
            {"daemon":"v1","started":"2026-11-14T18:54:39.1+09:00","uptime":12.5,"emacs":"online","streams":1,
             "listeners":[{"addr":"0.0.0.0:8766"}],"awake":true,"awakeHeld":true,"scheme":"http",
             "host":"100.64.1.2","port":8766}
            """
        let st = try JSONDecoder().decode(Status.self, from: Data(json.utf8))
        #expect(
            st
                == Status(
                    daemon: "v1", emacs: "online", streams: 1, awake: true, awakeHeld: true, scheme: "http",
                    host: "100.64.1.2", port: 8766))
        #expect(try JSONDecoder().decode(Status.self, from: Data("{}".utf8)) == Status())
    }

    @Test func urls() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tok = dir.appendingPathComponent("token").path
        try "secret\n".write(toFile: tok, atomically: true, encoding: .utf8)

        #expect(
            try remoteURL(Status(scheme: "http", host: "100.64.1.2", port: 8766), port: 0, tokenFile: tok)
                == "http://100.64.1.2:8766/overlook/#secret")
        #expect(try remoteURL(Status(port: 9), port: 0, tokenFile: tok) == "http://localhost:9/overlook/#secret")
        #expect(
            try remoteURL(nil, port: 8766, tokenFile: tok, host: { "192.168.1.5" })
                == "http://192.168.1.5:8766/overlook/#secret")
        #expect(throws: RemoteError.self) { try remoteURL(nil, port: 0, tokenFile: tok) }
        #expect(pageURL(scheme: "https", host: "::1", port: 443, token: "t") == "https://[::1]:443/overlook/#t")

        let empty = dir.appendingPathComponent("empty").path
        try " \n".write(toFile: empty, atomically: true, encoding: .utf8)
        for f in [empty, dir.appendingPathComponent("missing").path] {
            #expect(throws: RemoteError.self) { try remoteURL(Status(port: 1), port: 0, tokenFile: f) }
        }
    }

    @Test func preferredAddresses() {
        let lo = Interface(name: "lo0", addrs: [[127, 0, 0, 1]])
        let en = Interface(name: "en0", addrs: [[169, 254, 1, 1], [192, 168, 1, 5]])
        let ts = Interface(name: "utun4", addrs: [[100, 101, 2, 3]])
        let other = Interface(name: "bridge0", addrs: [[10, 0, 0, 1]])
        #expect(preferredAddress([lo, en, ts]) == "100.101.2.3")
        #expect(preferredAddress([other, en]) == "192.168.1.5")
        #expect(preferredAddress([lo, other]) == "10.0.0.1")
        #expect(preferredAddress([Interface(name: "x", addrs: [[100, 128, 0, 1]])]) == "100.128.0.1")
        #expect(preferredAddress([lo]) == "")
        #expect(!interfaces().isEmpty)
    }

    @Test func qrCodeDecodes() throws {
        let url = "http://100.64.1.2:8766/overlook/#0123456789abcdef0123456789abcdef"
        let cg = try #require(qrCode(url, scale: 8))
        #expect(cg.width == cg.height && cg.width % 8 == 0)
        let detector = try #require(
            CIDetector(
                ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [url])
    }
}

/// Answers launchctl commands from a table and records them.
final class FakeLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var services: [String: String] = [:]
    var disabled = ""
    var fail: Set<String> = []

    var calls: [String] {
        get { lock.withLock { _calls } }
        set { lock.withLock { _calls = newValue } }
    }

    var launchctl: Launchctl {
        Launchctl(path: "launchctl", uid: 501) { _, args in self.run(args) }
    }

    func run(_ args: [String]) -> (status: Int32, output: String) {
        lock.withLock { _calls.append(args.joined(separator: " ")) }
        if fail.contains(args[0]) { return (5, "Bad request.") }
        switch args[0] {
        case "print":
            let label = String(args[1].split(separator: "/").last!)
            guard let out = services[label] else { return (113, "Bad request.\nCould not find service") }
            return (0, out)
        case "print-disabled":
            return (0, disabled)
        default:
            return (0, "")
        }
    }
}

let printRunning =
    "gui/501/d = {\n\tactive count = 1\n\tstate = running\n\tprogram = /x\n\tsemaphores = {\n\t\tstate = waiting\n\t\tpid = 9\n\t}\n\tpid = 4242\n}\n"
let printStopped = "gui/501/d = {\n\tstate = not running\n\truns = 3\n}\n"
let printDisabled =
    "\tdisabled services = {\n\t\t\"com.other\" => enabled\n\t\t\"d\" => disabled\n\t\t\"m\" => false\n\t\t\"old\" => true\n\t}\n"

@Suite struct LaunchctlTests {
    @Test func parses() {
        #expect(parseService(printRunning) == Service(loaded: true, running: true, pid: 4242))
        #expect(parseService(printStopped) == Service(loaded: true))
        #expect(parseDisabled(printDisabled) == ["com.other": false, "d": true, "m": false, "old": true])
    }

    @Test(arguments: [
        ("running: nothing to do", ["d": printRunning], "", ["print gui/501/d"]),
        ("loaded but stopped: kickstart", ["d": printStopped], "", ["print gui/501/d", "kickstart gui/501/d"]),
        (
            "not loaded: bootstrap", [:], "",
            ["print gui/501/d", "print-disabled gui/501", "bootstrap gui/501 /p.plist"]
        ),
        (
            "not loaded and disabled: enable just for the bootstrap", [:], printDisabled,
            [
                "print gui/501/d", "print-disabled gui/501", "enable gui/501/d", "bootstrap gui/501 /p.plist",
                "disable gui/501/d",
            ]
        ),
    ])
    func start(_ name: String, _ services: [String: String], _ disabled: String, _ want: [String]) throws {
        let f = FakeLaunchctl()
        f.services = services
        f.disabled = disabled
        try f.launchctl.start("d", plist: "/p.plist")
        #expect(f.calls == want, "\(name)")
    }

    @Test func failingPrint() {
        let f = FakeLaunchctl()
        f.fail = ["print"]
        #expect {
            try f.launchctl.start("d", plist: "/p.plist")
        } throws: {
            "\($0)".contains("launchctl print gui/501/d: exit status 5: Bad request.")
        }
    }

    @Test func login() throws {
        let f = FakeLaunchctl()
        f.disabled = printDisabled
        let l = f.launchctl
        #expect(try l.loginEnabled(["m", "com.other"]))
        #expect(try !l.loginEnabled(["m", "d"]))
        #expect(try l.loginEnabled(["never-listed"]))
        f.calls = []
        try l.setLogin(false, ["d", "m"])
        try l.setLogin(true, ["d", "m"])
        #expect(f.calls == ["disable gui/501/d", "disable gui/501/m", "enable gui/501/d", "enable gui/501/m"])
        f.fail = ["enable"]
        #expect { try l.setLogin(true, ["d"]) } throws: { "\($0)".contains("Bad request") }
    }

    @Test func commands() throws {
        let f = FakeLaunchctl()
        let l = f.launchctl
        try l.bootout("d")
        try l.kickstart("d", kill: true)
        try l.kickstart("d", kill: false)
        #expect(try l.service("d") == Service())
        #expect(f.calls == ["bootout gui/501/d", "kickstart -k gui/501/d", "kickstart gui/501/d", "print gui/501/d"])
    }

    @Test func runsRealCommands() {
        #expect(runProcess("/bin/echo", ["hi"]) == (0, "hi\n"))
        #expect(runProcess("sh", ["-c", "echo err >&2; exit 3"]) == (3, "err\n"))
        #expect(runProcess("/no/such/launchctl", []).status == 127)
    }
}

/// A one-connection admin socket server that answers each request line with the lines reply returns.
final class FakeAdmin: @unchecked Sendable {
    let path: String
    private let fd: Int32
    let requests = Locked<[String]>([])

    init(reply: @escaping @Sendable (String) -> [String]) throws {
        path = "/tmp/olmb-\(UUID().uuidString.prefix(8)).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, listen(fd, 4) == 0 else { throw AdminError(description: "listen failed") }
        let (fd, requests) = (fd, requests)
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                var buf = Data()
                var byte: UInt8 = 0
                while read(c, &byte, 1) == 1 {
                    if byte != 0x0A {
                        buf.append(byte)
                        continue
                    }
                    let line = String(decoding: buf, as: UTF8.self)
                    buf.removeAll()
                    requests.mutate { $0.append(line) }
                    for out in reply(line) {
                        _ = (out + "\n").utf8CString.withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count - 1) }
                    }
                }
                close(c)
            }
        }
    }

    deinit {
        close(fd)
        unlink(path)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
    var get: T { lock.withLock { value } }
}

@Suite struct AdminTests {
    @Test func statusAndSetAwake() throws {
        let server = try FakeAdmin { line in
            line.contains("set-awake")
                ? [#"{"status":{"emacs":"online","awake":false}}"#]
                : [#"{"status":{"emacs":"online","awake":true,"streams":3}}"#]
        }
        #expect(try Admin.status(path: server.path) == Status(emacs: "online", streams: 3, awake: true))
        #expect(try Admin.setAwake(path: server.path, false) == Status(emacs: "online"))
        let reqs = try server.requests.get.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: any Sendable] as NSDictionary
        }
        #expect(reqs == [["op": "status"], ["op": "set-awake", "on": false]])
    }

    @Test func errorsAndWatch() throws {
        let server = try FakeAdmin { line in
            line.contains("watch")
                ? [#"{"status":{"emacs":"offline"}}"#, #"{"status":{"emacs":"online","streams":1}}"#]
                : [#"{"error":"unknown op"}"#]
        }
        #expect { try Admin.status(path: server.path) } throws: { "\($0)" == "unknown op" }
        let seen = Locked<[Status]>([])
        let conn = Locked<AdminConnection?>(nil)
        #expect(throws: AdminError.self) {
            try Admin.watch(path: server.path, onConnect: { c in conn.mutate { $0 = c } }) { st in
                seen.mutate { $0.append(st) }
                if seen.get.count == 2 { conn.get?.shutdown() }
            }
        }
        #expect(seen.get == [Status(emacs: "offline"), Status(emacs: "online", streams: 1)])
        #expect(throws: AdminError.self) { try Admin.status(path: "/tmp/no-such-overlook.sock") }
    }
}
