// Settings (⌘,): the family's small fixed window (dev/apps.md, «The small fixed window»; the layout of the shared
// window.swift): icon, name, version, Check for Updates…, then the app's rows (Shortcut, Keep on Top, Save To), Open at
// Login, the links and Quit. 340 pt wide, nothing to scroll, nothing that resizes.
import AppKit
import ServiceManagement

/// Open at Login: the agent in the bundle (./build writes it; main.swift, --login), as in the other apps.
let loginItem = SMAppService.agent(plistName: "\(Bundle.main.bundleIdentifier ?? "com.geragaraza.merum").login.plist")

// The app's own icon, as Finder shows it now: on macOS 26+ the icon follows the theme (Assets.car), so it is fetched
// again whenever the window's appearance changes; NSApp.applicationIconImage keeps the one from launch.
final class AppIconView: NSImageView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    // NSWorkspace hands the icon over at 32 x 32 pt and NSImageView only scales down, so it would show at half the
    // view's size: the image is given the view's size (the icon is multi-resolution, so it stays sharp).
    private func refresh() {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = bounds.size
        image = icon
    }
}

@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let recorder = ShortcutRecorder()
    private let status = NSTextField(labelWithString: "")
    private let keepOnTop = NSSwitch()
    private let saveTo = NSPopUpButton()
    private let login = NSSwitch()
    weak var app: App?

    static let width: CGFloat = 340, height: CGFloat = 382

    init(app: App) {
        self.app = app
        panel = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.titlebarAppearsTransparent = true
        panel.isExcludedFromWindowsMenu = true
        panel.isRestorable = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        build()
    }

    private func build() {
        let v = panel.contentView!
        let W = Self.width, M: CGFloat = 20

        func text(_ s: String, _ font: NSFont, _ color: NSColor, _ frame: NSRect, _ align: NSTextAlignment) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = font; l.textColor = color; l.alignment = align; l.frame = frame
            v.addSubview(l)
            return l
        }
        func label(_ s: String, _ y: CGFloat) {
            _ = text(s, .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: y, width: 150, height: 18), .left)
        }
        func toggle(_ sw: NSSwitch, _ y: CGFloat, _ action: Selector) {
            sw.controlSize = .small
            sw.sizeToFit()
            sw.frame.origin = NSPoint(x: W - M - sw.frame.width + 5, y: y)   // the switch draws 5 pt inside its frame
            sw.target = self; sw.action = action
            sw.refusesFirstResponder = true
            v.addSubview(sw)
        }

        // From the bottom up; each row 32 pt (the shared window's spacing).
        var x = M
        for (title, url) in [("Herman Harazha", "https://geragaraza.com"), ("GitHub", "https://github.com/geragarazagh/merum")] {
            let b = NSButton(title: title, target: self, action: #selector(openLink(_:)))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor])
            b.toolTip = url
            b.refusesFirstResponder = true
            b.sizeToFit()
            b.frame.origin = NSPoint(x: x, y: 20)
            v.addSubview(b)
            x += b.frame.width + 12
        }
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)
        quit.refusesFirstResponder = true
        quit.sizeToFit()
        quit.frame.origin = NSPoint(x: W - M - quit.frame.width, y: 16)
        v.addSubview(quit)

        label("Open at Login", 59)
        toggle(login, 58, #selector(loginChanged))

        label("Save To", 92)
        saveTo.controlSize = .regular
        saveTo.frame = NSRect(x: W - M - 160, y: 88, width: 160, height: 26)
        saveTo.target = self; saveTo.action = #selector(saveToChanged)
        saveTo.refusesFirstResponder = true
        v.addSubview(saveTo)

        label("Keep on Top", 127)
        toggle(keepOnTop, 126, #selector(keepOnTopChanged))

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.frame = NSRect(x: M, y: 150, width: W - 2 * M, height: 14)
        v.addSubview(status)

        label("Shortcut", 173)
        recorder.frame = NSRect(x: W - M - 160, y: 168, width: 160, height: 28)
        recorder.status = status
        recorder.onBegin = { [weak self] in self?.app?.hotKey.unregister() }
        recorder.onEnd = { [weak self] in
            guard let self, let app = self.app else { return }
            if !app.hotKey.register(self.recorder.shortcut) {
                self.status.stringValue = "This shortcut can’t be used"
                app.hotKey.register(.saved)
                self.recorder.shortcut = .saved
            } else {
                self.recorder.shortcut.save()
            }
        }
        recorder.onRecord = { s in refusal(s) }
        v.addSubview(recorder)

        let updates = NSButton(title: "Check for Updates…", target: Updates.shared, action: #selector(Updates.check))
        updates.bezelStyle = .rounded
        updates.controlSize = .small
        updates.font = .systemFont(ofSize: 11)
        updates.refusesFirstResponder = true
        updates.sizeToFit()
        updates.frame.origin = NSPoint(x: (W - updates.frame.width) / 2, y: 210)
        v.addSubview(updates)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        _ = text(version, .systemFont(ofSize: 11), .secondaryLabelColor, NSRect(x: M, y: 242, width: W - 2 * M, height: 14), .center)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Merum"
        _ = text(name, .boldSystemFont(ofSize: 15), .labelColor, NSRect(x: M, y: 258, width: W - 2 * M, height: 20), .center)
        v.addSubview(AppIconView(frame: NSRect(x: (W - 64) / 2, y: 284, width: 64, height: 64)))
    }

    func show() {
        refresh()
        if !panel.isVisible {
            // Over the main window's middle, as a sheet-less settings window of a one-window app.
            if let main = app?.main.window, main.isVisible {
                let f = main.frame
                panel.setFrameOrigin(NSPoint(x: (f.midX - Self.width / 2).rounded(), y: (f.midY - panel.frame.height / 2).rounded()))
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
        Updates.shared.appOpened()
    }

    func refresh() {
        recorder.shortcut = app?.hotKey.shortcut ?? .saved
        if !recorder.recording { status.stringValue = "" }
        keepOnTop.state = MainWindow.keepOnTop ? .on : .off
        login.state = loginItem.status == .enabled ? .on : .off
        saveTo.removeAllItems()
        saveTo.addItem(withTitle: "Ask Each Time")
        saveTo.lastItem?.tag = 0
        if let f = Saver.folder {
            saveTo.menu?.addItem(.separator())
            saveTo.addItem(withTitle: FileManager.default.displayName(atPath: f.path))
            let icon = NSWorkspace.shared.icon(forFile: f.path)
            icon.size = NSSize(width: 16, height: 16)
            saveTo.lastItem?.image = icon
            saveTo.lastItem?.tag = 1
            saveTo.lastItem?.toolTip = f.path
        }
        saveTo.menu?.addItem(.separator())
        saveTo.addItem(withTitle: "Other…")
        saveTo.lastItem?.tag = 2
        saveTo.selectItem(withTag: Saver.folder == nil ? 0 : 1)
    }

    func windowDidBecomeKey(_ n: Notification) { login.state = loginItem.status == .enabled ? .on : .off }
    func windowDidResignKey(_ n: Notification) { recorder.end() }
    func windowWillClose(_ n: Notification) { recorder.end() }

    @objc private func openLink(_ b: NSButton) {
        if let s = b.toolTip, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    @objc private func keepOnTopChanged() { app?.main.toggleKeepOnTop(nil) }

    @objc private func saveToChanged() {
        switch saveTo.selectedTag() {
        case 0: Saver.folder = nil
        case 2:
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.allowsMultipleSelection = false
            p.prompt = "Choose"
            p.directoryURL = Saver.folder ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            p.beginSheetModal(for: panel) { [weak self] r in
                MainActor.assumeIsolated {
                    if r == .OK, let url = p.url { Saver.folder = url }
                    self?.refresh()
                }
            }
            return
        default: break
        }
        refresh()
    }

    @objc private func loginChanged() {
        do {
            if login.state == .on {
                if loginItem.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } else { try loginItem.register() }
            } else {
                try loginItem.unregister()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Open at Login could not be changed."
            a.informativeText = "\(error.localizedDescription)"
            a.beginSheetModal(for: panel)
        }
        login.state = loginItem.status == .enabled ? .on : .off
    }
}

/// Esc closes it, as any settings window (⌘W through File > Close).
final class SettingsPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}
