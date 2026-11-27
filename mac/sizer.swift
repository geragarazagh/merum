// The window's minimum, measured rather than assumed (window.swift, «The smallest window»): a copy of the toolbar in a
// window that is never shown is laid out by AppKit at narrower and narrower widths until a button would go into the »
// overflow or the search field would fold to its magnifier. AppKit lays out a window's bar the same whether it is on
// screen or not (measured on macOS 26.6: the same widths to the point, on screen and off), and the bar's title gives
// way before any button does (the same widths with a one-letter title and a 70-character one), so the note's name
// plays no part.
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
        let key = "windowMinimum"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let signature = bar.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
            + " | \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) | \(NSFont.systemFontSize) \(NSFont.smallSystemFontSize)"
        if let kept = UserDefaults.standard.dictionary(forKey: key), kept["signature"] as? String == signature,
           let e = kept["editor"] as? Double, let h = kept["height"] as? Double {
            return Need(editor: e, height: h)
        }
        let need = measured(bar)
        UserDefaults.standard.set(["signature": signature, "editor": Double(need.editor), "height": Double(need.height)], forKey: key)
        return need
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

    /// The smallest window width (to the point) at which the whole bar fits.
    private func narrowest(_ w: NSWindow, _ settle: () -> Void) -> CGFloat {
        var lo: CGFloat = 120, hi: CGFloat = 2400
        func fits(_ width: CGFloat) -> Bool {
            var f = w.frame; f.size.width = width
            w.setFrame(f, display: false)
            settle()
            w.layoutIfNeeded()
            return whole(w)
        }
        guard fits(hi) else { return hi }
        while hi - lo > 1 {
            let mid = ((lo + hi) / 2).rounded()
            if fits(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }

    /// Every item in the bar, the search as a field.
    private func whole(_ w: NSWindow) -> Bool {
        guard let tb = w.toolbar else { return true }
        let spacers: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
        let wanted = Set(tb.items.map(\.itemIdentifier)).subtracting(spacers)
        let shown = Set((tb.visibleItems ?? []).map(\.itemIdentifier)).subtracting(spacers)
        guard wanted.isSubset(of: shown) else { return false }
        for case let s as NSSearchToolbarItem in tb.items where s.searchField.isHiddenOrHasHiddenAncestor { return false }
        return true
    }

    /// The copy: the main window's style, a sidebar split, a bar of the same items in the same order.
    private func twin(_ items: [NSToolbarItem.Identifier]) -> NSWindow {
        if let window, ids == items { return window }
        ids = items
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
        window?.close()
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
