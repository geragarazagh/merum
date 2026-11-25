// The global hot key that shows and hides the window, and the button that records a new one.
//
// - Carbon's RegisterEventHotKey: no Accessibility permission, and the key is a virtual key code (a physical key), so it
//   works in every keyboard layout. It reaches the app while it is hidden and in the background.
// - macOS does not report a key another app holds (RegisterEventHotKey answers noErr) and acts on most of its own keys
//   before an app hears them; the ones it lists as its own (CopySymbolicHotKeys) are refused when recorded, as are keys
//   this app's own menus use, a key with no ⌘, ⌥ or ⌃ (it would stop that letter typing everywhere) and ⌘ with nothing
//   else (it would take an app's own command, ⌘V or ⌘Q, from every app).
import AppKit
import Carbon.HIToolbox

struct Shortcut: Equatable {
    var key: Int    // virtual key code
    var mods: Int   // Carbon modifiers: cmdKey, optionKey, controlKey, shiftKey

    /// ⌥⌘M until the person picks another: M for Merum (the owner's choice, 2026-11-25). It shadows «Minimize All»
    /// (⌥⌘M in other apps' Window menus, rarely used) while Merum runs; accepted. The one place the default lives.
    static let standard = Shortcut(key: kVK_ANSI_M, mods: optionKey | cmdKey)

    static var saved: Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotKeyCode") != nil else { return .standard }
        return Shortcut(key: d.integer(forKey: "hotKeyCode"), mods: d.integer(forKey: "hotKeyMods"))
    }
    func save() {
        UserDefaults.standard.set(key, forKey: "hotKeyCode")   // nosemgrep (a shortcut key code in the app's own defaults, not a secret)
        UserDefaults.standard.set(mods, forKey: "hotKeyMods")   // nosemgrep (a shortcut key code in the app's own defaults, not a secret)
    }

    init(key: Int, mods: Int) { self.key = key; self.mods = mods }
    init(_ e: NSEvent) {
        let f = e.modifierFlags
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        self.init(key: Int(e.keyCode), mods: m)
    }

    /// «⌃⌥⌘N», modifiers in the order macOS writes them.
    var title: String {
        (mods & controlKey != 0 ? "⌃" : "") + (mods & optionKey != 0 ? "⌥" : "")
            + (mods & shiftKey != 0 ? "⇧" : "") + (mods & cmdKey != 0 ? "⌘" : "") + keyName(key)
    }

    var cocoaMods: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & cmdKey != 0 { f.insert(.command) }
        if mods & optionKey != 0 { f.insert(.option) }
        if mods & controlKey != 0 { f.insert(.control) }
        if mods & shiftKey != 0 { f.insert(.shift) }
        return f
    }
}

private let functionKeys: [Int: String] = [
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
    kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
    kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"]

private let namedKeys: [Int: String] = [
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
    kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦", kVK_Delete: "⌫", kVK_Return: "↩", kVK_Tab: "⇥",
    kVK_Space: "Space", kVK_Escape: "⎋", kVK_ANSI_KeypadEnter: "⌤"]

/// The Latin character of a key whatever layout is on: a shortcut reads ⌃⌥⌘N, not ⌃⌥⌘Т.
func keyName(_ key: Int) -> String {
    if let name = functionKeys[key] ?? namedKeys[key] { return name }
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
    let data = unsafeBitCast(raw, to: CFData.self)
    let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
    var dead: UInt32 = 0, count = 0
    var chars = [UniChar](repeating: 0, count: 4)
    UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &count, &chars)
    return String(utf16CodeUnits: chars, count: count).uppercased()
}

/// A key macOS lists as its own and has switched on (Spotlight, Mission Control, screenshots, input sources…).
func takenByMacOS(_ s: Shortcut) -> Bool {
    var list: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&list) == noErr, let all = list?.takeRetainedValue() as? [[String: Any]] else { return false }
    let mask = cmdKey | optionKey | controlKey | shiftKey
    return all.contains {
        ($0[kHISymbolicHotKeyEnabled] as? Bool) == true && ($0[kHISymbolicHotKeyCode] as? Int) == s.key
            && (($0[kHISymbolicHotKeyModifiers] as? Int) ?? -1) & mask == s.mods
    }
}

/// A key one of this app's menu items uses (⌘N, ⌃⌘S…): as a global key it would take that command away.
func takenByMenus(_ s: Shortcut) -> Bool {
    guard let main = NSApp.mainMenu else { return false }
    let typed = keyName(s.key).lowercased()
    func walk(_ m: NSMenu) -> Bool {
        for it in m.items {
            if let sub = it.submenu, walk(sub) { return true }
            guard !it.keyEquivalent.isEmpty else { continue }
            var mods = it.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            var ch = it.keyEquivalent
            // An upper-case key equivalent carries ⇧ by itself.
            if ch != ch.lowercased() { mods.insert(.shift); ch = ch.lowercased() }
            if ch == typed && mods == s.cocoaMods { return true }
        }
        return false
    }
    return walk(main)
}

/// Why a shortcut can't be the hot key, or nil when it can.
func refusal(_ s: Shortcut) -> String? {
    // The default is always allowed back: macOS 27 lists ⌥⌘M among its own keys (Minimize All, a menu command the apps
    // carry, not a key macOS takes first: the press reaches Merum, measured 2026-11-25), and the owner chose it so.
    if s == .standard { return nil }
    if s.mods & (cmdKey | optionKey | controlKey) == 0 && functionKeys[s.key] == nil { return "Needs ⌘, ⌥ or ⌃" }
    if s.mods == cmdKey && functionKeys[s.key] == nil { return "Add ⇧, ⌥ or ⌃" }
    if takenByMacOS(s) { return "Conflicts with macOS" }
    if takenByMenus(s) { return "Already in use" }
    return nil
}

/// Carbon's handler is a C function and can capture nothing.
private var hotKeyAction: (() -> Void)?

@MainActor final class HotKey {
    private var ref: EventHotKeyRef?
    private(set) var shortcut = Shortcut.saved

    init(action: @escaping () -> Void) {
        hotKeyAction = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult func register(_ s: Shortcut? = nil) -> Bool {
        unregister()
        if let s { shortcut = s }
        let id = EventHotKeyID(signature: OSType(0x4D52_4D4E), id: 1)   // 'MRMN'
        return RegisterEventHotKey(UInt32(shortcut.key), UInt32(shortcut.mods), id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    /// While a new key is recorded: a registered key never reaches the app as a key press, so the same key pressed
    /// again could not be recorded.
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// The Shortcut row's button: shows the key; a click asks for a new one («Press a shortcut»), Esc or a click again
/// leaves it as it was. The status line under it says why a key was refused.
@MainActor final class ShortcutRecorder: NSButton {
    var shortcut = Shortcut.standard { didSet { refresh() } }
    /// A key was chosen; returns why it can't be used, or nil when it was taken.
    var onRecord: ((Shortcut) -> String?)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var status: NSTextField?
    private var monitor: Any?
    var recording: Bool { monitor != nil }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.pushOnPushOff)
        refusesFirstResponder = true
        target = self; action = #selector(clicked)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = recording ? "Press a shortcut" : shortcut.title
        state = recording ? .on : .off
    }

    @objc private func clicked() { if recording { end() } else { begin() } }

    func begin() {
        guard monitor == nil else { return }
        onBegin?()
        status?.stringValue = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let s = Shortcut(e)
            if s.key == kVK_Escape && s.mods == 0 { self.end(); return nil }
            if let why = self.onRecord?(s) { self.status?.stringValue = why; return nil }
            self.shortcut = s
            self.end()
            return nil
        }
        refresh()
    }

    func end() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        refresh()
        onEnd?()
    }
}
