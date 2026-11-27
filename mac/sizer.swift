// The window's minimum, measured rather than assumed (window.swift, «The smallest window»): a copy of the toolbar in a
// window that is never shown is laid out by AppKit at narrower and narrower widths until a button would go into the »
// overflow or the search field would fold to its magnifier. AppKit lays out a window's bar the same whether it is on
// screen or not (measured on macOS 26.6: the same widths to the point, on screen and off), and the bar's title gives
// way before any button does (the same widths with a one-letter title and a 70-character one), so the note's name
// plays no part.
//
// What counts as «the whole bar» is what the bar shows when the window is as wide as the search goes, not every item it
// holds: items the person put before the sidebar's tracking separator sit over the sidebar, in a part of the bar as wide
// as the sidebar, and no window width brings them back from the overflow when the sidebar is too narrow for them (on
// macOS 27 the traffic lights, the sidebar button and New Note need ~190 pt there, the sidebar's narrowest is 182). Before
// 2026-11-27 the search waited for every item to show, never saw it, and took its widest try as the answer: the bar
// [sidebar button, New Note, tracking separator] made a minimum of 2400 pt on a 1728 pt screen, a window that could
// not be made smaller and a Customize Toolbar… sheet out of sight.
import AppKit

@MainActor final class Sizer: NSObject, NSToolbarDelegate {
    private weak var main: MainWindow?
    private var ids: [NSToolbarItem.Identifier] = []
    private var window: NSWindow?
    private var split: NSSplitViewController?

    init(main: MainWindow) { self.main = main }

    struct Need { var editor: CGFloat; var height: CGFloat }

    /// The narrowest whole note beside the sidebar at its narrowest, and the lowest whole window. A measure takes 15-110 ms
    /// (test machines, macOS 13 and 27), so its result is kept with what it depends on (the bar's items, the system and
    /// its text size) and measured again only when one of them changes.
    func measure() -> Need {
        guard let main, let bar = main.window?.toolbar else { return Need(editor: 360, height: 332) }
        let key = "windowMinimum"   // nosemgrep (the name of a settings key, not a secret)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // «2»: measures kept by the search before 2026-11-27 are not trusted (see the head of this file).
        let signature = "2 | " + bar.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
            + " | \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) | \(NSFont.systemFontSize) \(NSFont.smallSystemFontSize)"
        if let kept = UserDefaults.standard.dictionary(forKey: key), kept["signature"] as? String == signature,
           let e = kept["editor"] as? Double, let h = kept["height"] as? Double, Self.sane(e, h) {
            return Need(editor: e, height: h)
        }
        let need = measured(bar)
        UserDefaults.standard.set(["signature": signature, "editor": Double(need.editor), "height": Double(need.height)], forKey: key)   // nosemgrep (a measured window size, not a secret)
        return need
    }

    /// The widest window the search tries; a bar that needs more than this is wider than any screen made.
    static let widest: CGFloat = 2400

    /// A kept measure inside what a measure can give: anything else (a value from an older search, a damaged setting) is
    /// measured again.
    static func sane(_ editor: Double, _ height: Double) -> Bool {
        editor.isFinite && height.isFinite && editor >= 200 && height >= 100
            && editor + Double(MainWindow.sidebarMin) < Double(widest) && height < 2000
    }

    private func measured(_ bar: NSToolbar) -> Need {
        let side = MainWindow.sidebarMin
        let w = twin(bar.items.map(\.itemIdentifier))
        guard let split else { return Need(editor: 360, height: 332) }
        // Sidebar shown at its narrowest: the note's part of the bar; sidebar hidden: the whole bar, which then also
        // carries the traffic lights, the sidebar button and New Note. The window must hold both.
        split.splitViewItems[0].isCollapsed = false
        let shown = narrowest(w) { w.layoutIfNeeded(); split.splitView.setPosition(side, ofDividerAt: 0) }
        let sideWidth = split.splitViewItems[0].viewController.view.frame.width
        split.splitViewItems[0].isCollapsed = true
        let hidden = narrowest(w) {}
        split.splitViewItems[0].isCollapsed = false
        let editor = max(shown - (sideWidth > 0 ? sideWidth : side), hidden - side, Self.countsWidth, 200).rounded(.up)
        // The bar's height (the frame less the content's layout rect) and five two-line rows of the list.
        let barHeight = w.frame.height - w.contentLayoutRect.height
        let height = (barHeight + 5 * NoteCell.height).rounded(.up)
        return Need(editor: editor, height: height)
    }

    /// The counts line whole for the largest note the app is made for (ten million characters, AGENTS.md) and a margin:
    /// eight-digit counts in the line's font, plus the field's 8 pt on each side.
    static var countsWidth: CGFloat {
        let line = Facts(characters: 88_888_888, words: 88_888_888, tokens: 88_888_888).line
        let w = (line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width
        return (w + 2 * 8 + 4).rounded(.up)
    }

    /// The smallest window width (to the point) at which the bar shows all it shows at the widest: as many items out of
    /// the » overflow, and the search as a field if it is one there. An item that stays in the overflow at any width (one
    /// over a sidebar too narrow for it) is not waited for.
    private func narrowest(_ w: NSWindow, _ settle: () -> Void) -> CGFloat {
        var lo: CGFloat = 120, hi: CGFloat = Self.widest
        func look(_ width: CGFloat) -> Look {
            var f = w.frame; f.size.width = width
            w.setFrame(f, display: false)
            settle()
            w.layoutIfNeeded()
            return Look(w)
        }
        let whole = look(hi)
        while hi - lo > 1 {
            let mid = ((lo + hi) / 2).rounded()
            if look(mid).holds(whole) { hi = mid } else { lo = mid }
        }
        // AppKit's bar keeps a little memory of where it came from: on macOS 27 an item can come back out of the » a few
        // points wider when the window grows to a width than when it shrinks to it, and the other way round (random bars
        // without the tracking separator, up to 4 pt). The answer holds from both sides: reached from the narrowest
        // window and from the widest.
        // Plus one point, the search's own step: the window itself turned out a point short of the copy for one bar in
        // 4,605 on macOS 27 (the fit lies somewhere inside the last point, and the two windows round it apart).
        func grown(_ width: CGFloat) -> Bool {
            _ = look(lo); guard look(width).holds(whole) else { return false }
            _ = look(Self.widest); return look(width).holds(whole)
        }
        guard !grown(hi) else { return hi + 1 }
        var below = hi, step: CGFloat = 2
        var above = min(hi + step, Self.widest)
        while above < Self.widest && !grown(above) { below = above; step *= 2; above = min(hi + step, Self.widest) }
        while above - below > 1 {
            let mid = ((below + above) / 2).rounded()
            if grown(mid) { above = mid } else { below = mid }
        }
        return above + 1
    }

    /// What the bar shows at one width: its items out of the overflow (spaces aside: they give way first and are no
    /// button), and whether every search item is a field rather than its magnifier.
    private struct Look {
        var items = 0
        var searchField = true
        init(_ w: NSWindow) {
            guard let tb = w.toolbar else { return }
            let spacers: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
            items = (tb.visibleItems ?? []).filter { !spacers.contains($0.itemIdentifier) }.count
            for case let s as NSSearchToolbarItem in tb.items where s.searchField.isHiddenOrHasHiddenAncestor { searchField = false }
        }
        func holds(_ whole: Look) -> Bool { items >= whole.items && (searchField || !whole.searchField) }
    }

    /// The copy: the main window's style, a sidebar split, a bar of the same items in the same order.
    private func twin(_ items: [NSToolbarItem.Identifier]) -> NSWindow {
        if let window, ids == items { return window }
        ids = items
        // Another set of items: the same copy, its bar given the new items as Customize Toolbar… gives them (a window per
        // set piled up: thousands of sets in the trial, each one slower than the last).
        if let window, let tb = window.toolbar {
            while !tb.items.isEmpty { tb.removeItem(at: 0) }
            for (i, id) in items.enumerated() { tb.insertItem(withItemIdentifier: id, at: i) }
            return window
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.titleVisibility = .visible
        w.title = "Merum"
        let s = NSSplitViewController()
        let a = NSViewController(); a.view = NSView()
        let b = NSViewController(); b.view = NSView()
        let side = NSSplitViewItem(sidebarWithViewController: a)
        side.minimumThickness = MainWindow.sidebarMin
        side.maximumThickness = MainWindow.sidebarMin
        side.canCollapse = true
        let note = NSSplitViewItem(viewController: b)
        note.minimumThickness = 10
        s.addSplitViewItem(side); s.addSplitViewItem(note)
        w.contentViewController = s
        w.minSize = NSSize(width: 50, height: 50)
        // A bar of its own (another identifier), never saved: the main bar's configuration is the person's.
        let tb = NSToolbar(identifier: "Merum Measure")
        tb.delegate = self
        tb.displayMode = main?.window?.toolbar?.displayMode ?? .iconOnly
        tb.allowsUserCustomization = false
        tb.autosavesConfiguration = false
        w.toolbar = tb
        w.toolbarStyle = main?.window?.toolbarStyle ?? .unified
        w.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 500), display: false)
        window = w; split = s
        return w
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // The main window's own items as it makes them for the Customize palette (flag false): the same look and size,
        // tied to nothing of the window's (its search and its «…» menu stay the bar's).
        guard let main, let bar = main.window?.toolbar else { return nil }
        return main.toolbar(bar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)
    }
}
