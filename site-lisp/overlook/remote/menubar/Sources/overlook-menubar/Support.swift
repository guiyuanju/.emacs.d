import AppKit
import Foundation
import MenubarCore

/// Writes slog-style text lines to stderr, which the LaunchAgent sends to the log file.
enum Log {
    static func write(_ level: String, _ msg: String, _ attrs: KeyValuePairs<String, String> = [:]) {
        let time = Date.now.ISO8601Format(.iso8601(timeZone: .current, includingFractionalSeconds: true))
        var line = "time=\(time) level=\(level) msg=\(quote(msg))"
        for (k, v) in attrs { line += " \(k)=\(quote(v))" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func info(_ msg: String, _ attrs: KeyValuePairs<String, String> = [:]) { write("INFO", msg, attrs) }
    static func warn(_ msg: String, _ attrs: KeyValuePairs<String, String> = [:]) { write("WARN", msg, attrs) }
    static func error(_ msg: String, _ attrs: KeyValuePairs<String, String> = [:]) { write("ERROR", msg, attrs) }

    private static func quote(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "=" || $0 == "\"" }) || s.isEmpty
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
    }
}

/// The status item's template images: SF Symbols phones, so macOS tints them for light and dark menu bars.
enum Icons {
    static let names: [(IconState, String, String)] = [
        (.online, "iphone.radiowaves.left.and.right", "Remote online"),
        (.emacsOffline, "iphone", "Emacs not connected"),
        (.stopped, "iphone.slash", "Remote stopped"),
    ]

    static var available: Bool {
        names.allSatisfy { NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) != nil }
    }

    @MainActor static func image(_ state: IconState) -> NSImage? {
        guard let (_, name, label) = names.first(where: { $0.0 == state }),
            let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        else { return nil }
        let sized = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? image
        sized.isTemplate = true
        return sized
    }
}

/// Follows the daemon's admin socket on its own thread, reporting nil while it does not answer.
final class Watcher: @unchecked Sendable {
    private let path: String
    private let poke = DispatchSemaphore(value: 0)
    private let onStatus: @Sendable (Status?) -> Void

    /// How long to wait before dialing the admin socket again.
    static let retry: Double = 1

    init(path: String, onStatus: @escaping @Sendable (Status?) -> Void) {
        self.path = path
        self.onStatus = onStatus
    }

    func start() {
        let t = Thread { [self] in loop() }
        t.name = "admin-watch"
        t.start()
    }

    /// Dials again now instead of after the retry delay.
    func wake() { poke.signal() }

    private func loop() {
        while true {
            do {
                try Admin.watch(path: path) { onStatus($0) }
            } catch {
                onStatus(nil)
            }
            _ = poke.wait(timeout: .now() + Self.retry)
            while poke.wait(timeout: .now()) == .success {}
        }
    }
}

/// The window showing the page URL as a QR code for the phone's camera. The URL carries the token, so the image is
/// dropped when the window closes.
@MainActor
final class QRWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(url: String) throws {
        guard let cg = qrCode(url, scale: 8) else { throw RemoteError(description: "cannot make a QR code") }
        let side = CGFloat(cg.width) / 2
        let w = window ?? makeWindow()
        let imageView = NSImageView(image: NSImage(cgImage: cg, size: NSSize(width: side, height: side)))
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityLabel("QR code of the Remote page URL")
        let hint = NSTextField(labelWithString: "Scan with the phone's camera")
        hint.font = .systemFont(ofSize: NSFont.systemFontSize)
        let host = NSTextField(labelWithString: url.components(separatedBy: "#").first ?? "")
        host.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        host.textColor = .secondaryLabelColor
        host.isSelectable = true
        let stack = NSStackView(views: [imageView, hint, host])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        if !w.isVisible { w.center() }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let w = ClosableWindow(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Overlook Remote"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }
}

/// A window that Escape and ⌘W close, since this app has no main menu to bind them.
final class ClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "w"
        {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
