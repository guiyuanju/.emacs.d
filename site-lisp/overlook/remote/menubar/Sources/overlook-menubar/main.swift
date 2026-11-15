import AppKit
import MenubarCore

let config: Config
do {
    config = try Config.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("overlook-menubar: \(error)\n\(Config.usage)\n".utf8))
    exit(2)
}
if config.help {
    print(Config.usage)
    exit(0)
}
if config.check {
    guard Icons.available else {
        FileHandle.standardError.write(Data("overlook-menubar: a menu bar symbol is missing\n".utf8))
        exit(1)
    }
    print("overlook-menubar: ok")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController(config: config)
app.delegate = controller
app.run()
