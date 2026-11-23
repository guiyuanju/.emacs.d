import AppKit
import MenubarCore

/// The status item and its menu. launchctl and admin socket calls run on a background queue; the UI on the main actor.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// How long a message replaces the status line.
    static let flashFor: TimeInterval = 4

    private let config: Config
    private let launchctl: Launchctl
    private let work = DispatchQueue(label: "overlook-menubar.work")
    private var watcher: Watcher!
    private let qr = QRWindow()

    private var item: NSStatusItem!
    private var status: Status?
    private var iconState: IconState?
    private var flash: (text: String, until: Date)?
    private var loginOn = false

    private let statusLine = NSMenuItem(title: "Remote stopped", action: nil, keyEquivalent: "")
    private lazy var copyItem = menuItem("Copy URL", #selector(copyURL))
    private lazy var qrItem = menuItem("Show QR Code", #selector(showQR))
    private lazy var awakeItem = menuItem("Keep Mac Awake", #selector(toggleAwake))
    private lazy var loginItem = menuItem("Start at Login", #selector(toggleLogin))
    private lazy var restartItem = menuItem("Restart Remote", #selector(restart))
    private lazy var emacsItem = menuItem("Restart Emacs", #selector(restartEmacs))
    private lazy var logItem = menuItem("Open Log", #selector(openLog))
    private lazy var quitItem = menuItem("Quit and Stop Remote", #selector(quit))

    init(config: Config) {
        self.config = config
        launchctl = Launchctl(path: config.launchctl)
        super.init()
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("starting", ["daemon": config.daemonLabel, "admin-socket": config.adminSocket])
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        copyItem.toolTip = "Copy the page's address, with its token"
        qrItem.toolTip = "Show the page's address as a QR code for the phone's camera"
        awakeItem.toolTip = "Prevent idle sleep while Remote runs; the display still sleeps"
        loginItem.toolTip = "Start Remote and this menu when you log in"
        logItem.toolTip = config.log
        quitItem.toolTip = "Stop overlook-remoted, then quit this menu"
        emacsItem.toolTip = "Save modified files, quit Emacs and start it again"
        statusLine.isEnabled = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for i in [
            statusLine, .separator(), copyItem, qrItem, .separator(), awakeItem, loginItem, .separator(), emacsItem,
            restartItem, logItem, .separator(), quitItem,
        ] {
            menu.addItem(i)
        }
        item.menu = menu
        render()

        watcher = Watcher(path: config.adminSocket) { st in
            Task { @MainActor in self.setStatus(st) }
        }
        watcher.start()
        refreshLogin()
        let (lc, label, plist) = (launchctl, config.daemonLabel, config.daemonPlist)
        background("starting Remote", { try lc.start(label, plist: plist) }) { _ in self.watcher.wake() }
    }

    func menuWillOpen(_ menu: NSMenu) { refreshLogin() }

    // MARK: State

    private func setStatus(_ st: Status?) {
        guard st != status else { return }
        status = st
        render()
    }

    private func render() {
        let m = Menu(status)
        if iconState != m.state {
            if iconState != nil { Log.info("state", ["status": m.status]) }
            item.button?.image = Icons.image(m.state)
            iconState = m.state
        }
        if let flash, flash.until > .now {
            statusLine.title = flash.text
        } else {
            statusLine.title = m.status
        }
        item.button?.toolTip = "overlook remote: \(m.status)"
        awakeItem.state = m.awake ? .on : .off
        awakeItem.title = m.awakeTitle
        awakeItem.isEnabled = m.awakeEnabled
        restartItem.title = m.restart
        emacsItem.isHidden = m.emacsRestart == nil
        emacsItem.title = m.emacsRestart ?? "Restart Emacs"
        emacsItem.isEnabled = m.emacsRestartEnabled
        let urlKnown = status != nil || config.port != 0
        copyItem.isEnabled = urlKnown
        qrItem.isEnabled = urlKnown
        loginItem.state = loginOn ? .on : .off
    }

    /// Shows text in place of the status line for a few seconds.
    private func say(_ text: String) {
        flash = (text, Date.now.addingTimeInterval(Self.flashFor))
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashFor + 0.01) {
            MainActor.assumeIsolated { self.render() }
        }
    }

    private func fail(_ what: String, _ error: any Error) {
        Log.error(what, ["err": "\(error)"])
        say("\(what) failed: \(error)")
    }

    /// Runs body on the work queue, then hands its result to done on the main actor, or reports the failure.
    private func background<T: Sendable>(
        _ what: String, _ body: @escaping @Sendable () throws -> T,
        done: @escaping @MainActor (T) -> Void = { _ in }
    ) {
        work.async {
            let r = Result { try body() }
            Task { @MainActor in
                switch r {
                case .success(let v): done(v)
                case .failure(let e): self.fail(what, e)
                }
            }
        }
    }

    private func url() throws -> String {
        try remoteURL(status, port: config.port, tokenFile: config.tokenFile)
    }

    // MARK: Actions

    @objc private func copyURL() {
        do {
            let u = try url()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(u, forType: .string)
            say("URL copied")
        } catch {
            fail("Copy URL", error)
        }
    }

    @objc private func showQR() {
        do {
            try qr.show(url: try url())
        } catch {
            fail("Show QR code", error)
        }
    }

    @objc private func toggleAwake() {
        guard let st = status else { return }
        let path = config.adminSocket
        let on = !st.awake
        background("Keep Mac awake", { try Admin.setAwake(path: path, on) }) { st in
            self.setStatus(st)
        }
    }

    private func refreshLogin() {
        let (lc, labels) = (launchctl, [config.daemonLabel, config.label])
        work.async {
            let on: Bool
            do {
                on = try lc.loginEnabled(labels)
            } catch {
                Log.warn("reading start at login", ["err": "\(error)"])
                return
            }
            Task { @MainActor in
                self.loginOn = on
                self.render()
            }
        }
    }

    @objc private func toggleLogin() {
        let (lc, labels, on) = (launchctl, [config.daemonLabel, config.label], !loginOn)
        background("Start at login", { try lc.setLogin(on, labels) }) { _ in self.refreshLogin() }
    }

    @objc private func restart() {
        let (lc, label, plist) = (launchctl, config.daemonLabel, config.daemonPlist)
        let done: @MainActor (()) -> Void = { _ in self.watcher.wake() }
        if status == nil {
            say("Starting Remote…")
            background("Start", { try lc.start(label, plist: plist) }, done: done)
        } else {
            say("Restarting Remote…")
            background("Restart", { try lc.kickstart(label, kill: true) }, done: done)
        }
    }

    @objc private func restartEmacs() {
        if Menu(status).emacsRestartConfirm {
            let alert = NSAlert()
            alert.messageText = "Restart Emacs?"
            alert.informativeText =
                "Modified files are saved, then Emacs quits and starts again. Agents running in Emacs stop."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let path = config.adminSocket
        background("Restart Emacs", { try Admin.restartEmacs(path: path) }) { st in self.setStatus(st) }
    }

    @objc private func openLog() {
        let log = URL(fileURLWithPath: config.log)
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            if !NSWorkspace.shared.open(log) { fail("Open log", RemoteError(description: "cannot open \(config.log)")) }
            return
        }
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    [log], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                if !NSWorkspace.shared.open(log) { fail("Open log", error) }
            }
        }
    }

    /// Stops the daemon, then quits; only this item stops the daemon, so a crash of the app does not.
    @objc private func quit() {
        quitItem.isEnabled = false
        say("Stopping Remote…")
        qr.close()
        let (lc, label) = (launchctl, config.daemonLabel)
        work.async {
            do { try lc.bootout(label) } catch { Log.error("stopping Remote", ["err": "\(error)"]) }
            Task { @MainActor in
                Log.info("quit")
                NSApp.terminate(nil)
            }
        }
    }
}
