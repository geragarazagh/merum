// The app: one window called and sent away by a global hot key. While the window is shown Merum is a regular app with
// a Dock icon and its full menu bar; hidden, it is an accessory app with neither, and never a menu bar icon
// (dev/merum.md). The hot key brings the window to the Space in use, over every window including a full-screen app's,
// focused on the last open note with the caret where it was; pressed again while Merum is in front, it hides and the
// app that was in front before gets the focus back (the red button, ⌘W and ⌘H do the same).
import AppKit

@MainActor final class App: NSObject, NSApplicationDelegate {
    let library: Library
    private(set) var main: MainWindow!
    private(set) var menus: Menus!
    private(set) var hotKey: HotKey!
    private(set) var settings: SettingsWindow?
    private let background: Bool
    private var server: CommandServer?
    private(set) var sync: Sync?
    private var settingsSync: SettingsSync?
    /// The window is shown (not hidden, not ordered out by a hide).
    private(set) var shown = false

    init(library: Library, background: Bool) {
        self.library = library
        self.background = background
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        menus = Menus(app: self)
        main = MainWindow(library: library)
        main.app = self
        menus.refreshNotes()
        hotKey = HotKey { [weak self] in self?.toggle() }
        #if TRIALS
        // A scripted run beside the person's own Merum leaves the hot key to it.
        let scripted = CommandLine.arguments.contains("--trial")
        #else
        let scripted = false
        #endif
        if !scripted && !hotKey.register() {
            // The saved key can't be had (another app took it first): the default, else none until a new one is set.
            hotKey.register(.standard)
        }
        _ = Updates.shared   // starts the daily check
        server = CommandServer(app: self)
        // iCloud only in a build that carries the CloudKit entitlement (without it CKContainer stops the process).
        if Sync.available {
            let s = Sync(library: library, database: CloudKitDatabase())
            s.start()
            sync = s
            NSApp.registerForRemoteNotifications()   // the zone's silent pushes; no alert, badge or sound is asked for
        }
        let ss = SettingsSync(library: library)
        ss.start()
        settingsSync = ss

        let nc = NotificationCenter.default
        // A Space switch that ends after a press to show: the window goes to the Space it ended on.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged = true; self?.settle() }
        }
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didHide() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync?.fetchNow() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.library.flush()
            }
        }
        // Kept on top: the main window floats; any other window of the app (About, Settings, Sparkle's, the spelling
        // and substitutions panels) floats too when it comes, so it is never behind the note.
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let w = n.object as? NSWindow, w !== self.main.window, w.sheetParent == nil else { return }
                if MainWindow.keepOnTop && w.level < .floating { w.level = .floating }
            }
        }
        if background { NSApp.setActivationPolicy(.accessory) } else { show() }
        EditorController.warmLanguages()
        #if TRIALS
        // With --trace: a heartbeat from the main thread every 50 ms; a gap over 150 ms is written down as a stall, and a
        // line a second says the app is alive (a watchdog outside reads it to catch a hang).
        if Trace.handle != nil {
            var last = CACurrentMediaTime(), lastBeat = last
            let beat = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    if now - last > 0.15 { Trace.log(String(format: "stall %.0f ms", (now - last - 0.05) * 1000)) }
                    if now - lastBeat > 1 { Trace.log("beat"); lastBeat = now }
                    last = now
                }
            }
            RunLoop.main.add(beat, forMode: .common)   // also while a menu is open or a window is resized
        }
        if let i = CommandLine.arguments.firstIndex(of: "--trial"), i + 1 < CommandLine.arguments.count {
            Trial.run(CommandLine.arguments[i + 1], app: self)
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        sync?.handlePush(userInfo)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ n: Notification) {
        main.saveCaret()
        library.flush()
    }

    // MARK: show and hide

    func toggle() {
        let inFront = shown && NSApp.isActive && !NSApp.isHidden && main.window?.isVisible == true
            && (NSApp.keyWindow === main.window || NSApp.keyWindow === settings?.panel)
        #if TRIALS
        Trace.log("press " + (inFront ? "hide" : "show") + " | " + Trace.state(self))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Trace.log("after | " + Trace.state(self)) }
        #endif
        if inFront { hide() } else { show() }
    }

    func show() {
        guard let w = main.window else { return }
        shown = true
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if w.isMiniaturized { w.deminiaturize(nil) }
        bringForward(w)
        sync?.setForeground(true)   // fetches every 15 s while the window is shown
        if w.firstResponder === w || w.firstResponder == nil { main.focusEditor() }
        Updates.shared.appOpened()
        // A press that lands while macOS is still switching Spaces (a swipe, Mission Control, an app going full
        // screen) can leave the window on the Space being left, or the activation refused: measured in a test machine,
        // 16 of 70 presses so. For a moment after the press the window is checked and brought again, onto the Space
        // that ends up in use, until it is in front there.
        showing = Date().addingTimeInterval(1.6)
        spaceChanged = false
        for d in [0.12, 0.3, 0.6, 1.0, 1.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.settle() }
        }
    }

    /// Until when a press to show is still being made good.
    private var showing: Date?
    private var spaceChanged = false

    private func bringForward(_ w: NSWindow) {
        // Off the Space in use (left there by a switch): out first, so ordering it in places it on the Space in use.
        if w.isVisible && !w.isOnActiveSpace { w.orderOut(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The press to show is made good: the window visible on the Space in use, Merum in front, the window key.
    private func settle() {
        guard shown, let until = showing, Date() < until, let w = main.window else { return }
        if w.isVisible && w.isOnActiveSpace && NSApp.isActive && (w.isKeyWindow || settings?.panel.isKeyWindow == true) { return }
        // The person clicked or typed elsewhere since the press: that is their choice, not a refused activation; only a
        // window left off the Space in use is still brought back.
        let since = 1.6 - until.timeIntervalSinceNow
        let input = [CGEventType.leftMouseDown, .rightMouseDown, .keyDown].map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
        if input < since - 0.1 && w.isVisible && w.isOnActiveSpace { showing = nil; return }
        // An activation takes a moment to arrive (over a second at times in a test machine): asked again on a timer, the
        // second request can land after a click the person made meanwhile and take the focus from it. So the activation
        // is asked again only when a Space switch ends after the press (spaceChanged); the timers mend only a window
        // left off the Space in use or not shown.
        if !spaceChanged && w.isVisible && w.isOnActiveSpace { return }
        spaceChanged = false
        #if TRIALS
        Trace.log(String(format: "settle since=%.2f input=%.2f | ", since, input) + Trace.state(self))
        #endif
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        bringForward(w)
    }

    /// Hides the app as ⌘H does: macOS gives the focus back to the app that was in front before.
    func hide() {
        library.flush()
        shown = false
        showing = nil
        NSApp.hide(nil)
    }

    @objc func hideFromMenu(_ sender: Any?) { hide() }

    private func didHide() {
        // A press right after a hide can show the app again before this notification arrives: then it stays. Hidden by
        // another app's Hide Others, it is hidden like by the hot key.
        #if TRIALS
        Trace.log("didHide | " + Trace.state(self))
        #endif
        guard NSApp.isHidden else { return }
        shown = false
        sync?.setForeground(false)
        settings?.panel.orderOut(nil)
        main.window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindow(app: self) }
        settings?.show()
    }
}
