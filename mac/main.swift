// Merum for Mac: plain-text notes in one window called by a hot key (⌥⌘M until the person sets another).
//
// Opened by a person it shows the window; started at login (--login, from the agent in the bundle) or with
// --background it shows nothing and waits for the hot key. merum-cli (cli.swift) runs from the same binary.
// The notes live in ~/Library/Application Support/Merum (the core's Store); the Mac's own settings (the hot key, Keep on
// Top, Save To, the window's frame) in the app's defaults. Network: iCloud and Sparkle's daily update check only.
import AppKit

let args = CommandLine.arguments

// Open at Login: launchd starts this copy with --login; it starts the app through `open -g … --background` and exits,
// because launchd kills what it started when the agent is unregistered (dev/apps.md, «Open at Login»).
if args.contains("--login") {
    if let me = Bundle.main.bundleIdentifier,
       !NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0 != .current }) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", Bundle.main.bundlePath, "--args", "--background"]
        try? p.run()
        p.waitUntilExit()
    }
    exit(0)
}

_ = MainActor.assumeIsolated { runCLI(args) }

// One copy at a time: two would write the same store. A second one started from a terminal shows the first's window.
if let me = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0 != .current }) {
    _ = CommandServer.send(.show)
    exit(0)
}

// The window never takes a Space of its own (it comes over the one in use, window.swift): no Enter Full Screen item.
UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])

MainActor.assumeIsolated {
    var dir = Store.defaultDirectory
    #if TRIALS
    if let i = args.firstIndex(of: "--data"), i + 1 < args.count { dir = URL(fileURLWithPath: args[i + 1]) }
    #endif
    let library = Library(store: Store(dir: dir))
    let app = NSApplication.shared
    let delegate = App(library: library, background: args.contains("--background"))
    app.delegate = delegate
    // Accessory until the window shows (App.show makes it regular): no Dock icon flashes for a background start.
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
