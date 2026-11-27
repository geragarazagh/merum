// The one window: the notes list in a sidebar and the open note beside it, a toolbar with the sidebar button and New
// Note (Apple Notes' compose button), the open note's name as the window's title. Its size and place are the person's,
// kept for good. The red button and ⌘W hide it as the hot key does (App.hide); the app keeps running for the key.
import AppKit

extension NSToolbarItem.Identifier {
    static let newNote = NSToolbarItem.Identifier("newNote")
    static let share = NSToolbarItem.Identifier("share")
    static let more = NSToolbarItem.Identifier("more")
    static let search = NSToolbarItem.Identifier("search")
    static let pin = NSToolbarItem.Identifier("pin")
    static let rename = NSToolbarItem.Identifier("rename")
    static let findInNote = NSToolbarItem.Identifier("findInNote")
    static let deleteNote = NSToolbarItem.Identifier("deleteNote")
}

@MainActor final class MainWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                   NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate, NSMenuDelegate,
                                   NSToolbarItemValidation {
    let library: Library
    let list: NotesListController
    let editor: EditorController
    let split = NSSplitViewController()
    private let sidebar: NSSplitViewItem
    weak var app: App?
    private var known: Set<UUID> = []
    /// The rename field and the find bar's field keep their own undo: the History's manager holds note steps only.
    private let fieldUndo = UndoManager()
    private var searchItem: NSSearchToolbarItem?

    /// The sidebar can be dragged «чуть-чуть», never all the way (his recording 2026-11-25, Reminders as the model):
    /// at its narrowest every default name up to the 98th is whole, the widest of them (Seventy-Seventh Note) in the bold
    /// of a selected row, plus the source list's 18 pt on each side (measured on macOS 27): 182 pt. At its widest
    /// 360 pt, where Reminders' sidebar stopped in the same recording; a longer name is cut with «…».
    static let sidebarMin: CGFloat = {
        let bold = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        let widest = (1...98).map { (Ordinal.noteName($0) as NSString).size(withAttributes: [.font: bold]).width }.max() ?? 0
        return (widest + 2 * 18).rounded(.up)
    }()
    static let sidebarMax: CGFloat = 360
    /// The smallest window is worked out from what it shows, not from numbers measured on one Mac (dev/rules.md, section
    /// 3): every toolbar item in the bar, never in the » overflow, the search as a field with its «Search» (AppKit folds
    /// it to a magnifier when the bar is short of room), the counts line whole, five notes in the list. The toolbar's
    /// needs are AppKit's own layout, measured on a copy of the bar in a window that is never shown (Sizer), so they stay
    /// right with another macOS, another text size or another set of buttons; measured again when the person changes
    /// the buttons. One minimum with the sidebar shown or hidden, as Apple Notes (its window never changes size when
    /// its sidebar comes or goes): the sidebar at its narrowest beside the narrowest whole editor. Before 2026-11-27
    /// the minimum was a number measured on macOS 27 (542 pt) that a width with the bar overflowing raised on the spot
    /// by setting the frame from windowDidResize: on his 16" the search folded to its icon below ~645 pt, a window
    /// manager's animation caught it in mid-move (a Center that went small, then grew to 808 pt), and in the monkey test
    /// the frame it set called windowDidResize again until the stack ran out.
    private(set) var editorMin: CGFloat = 360
    private var minHeight: CGFloat = 332
    var minimumSize: NSSize { NSSize(width: Self.sidebarMin + editorMin, height: minHeight) }
    private lazy var sizer = Sizer(main: self)
    /// The first window, «как открывается текст»: TextEdit's new-window measure, his TextEdit set to 98 characters by
    /// 32 lines, in this app's font (13 pt San Francisco: 6.64 pt a character, the mean of English and Russian text;
    /// 16 pt lines): text 651 x 512 pt, with the text's insets, the toolbar and the counts line an editor of 685 x 606,
    /// and the sidebar at a third of its range (182 + (360 - 182) / 3 = 241): 926 x 606 pt. The measure of the text,
    /// not of the screen, as TextEdit's: the same window on a 13" Air (about 63 % of its width) as on a big iMac. A
    /// screen too small for it gets the most of its visible area, never less than the minimum (firstFrame).
    static let defaultSize = NSSize(width: 926, height: 606)
    static let sidebarDefault: CGFloat = 241

    init(library: Library) {
        self.library = library
        list = NotesListController(library: library)
        editor = EditorController(library: library)
        sidebar = NSSplitViewItem(sidebarWithViewController: list)
        let w = MerumWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init(window: w)

        sidebar.minimumThickness = Self.sidebarMin
        sidebar.maximumThickness = Self.sidebarMax
        sidebar.canCollapse = true
        // Showing the sidebar takes its room from the note, as in Notes, Finder and Mail: the window keeps its frame (the
        // default grew the window to the right when the note was at its narrowest). The minimum leaves room for it.
        sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let main = NSSplitViewItem(viewController: editor)
        main.minimumThickness = editorMin
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(main)
        split.splitView.autosaveName = "Merum Sidebar"

        w.contentViewController = split
        w.delegate = self
        w.isReleasedWhenClosed = false
        // Nothing in Saved Application State: the window comes back by the app's own settings, not by restoration.
        w.isRestorable = false
        w.tabbingMode = .disallowed
        w.titleVisibility = .visible
        // Over every window of the Space it is called to, full-screen apps included; it never takes a Space of its own,
        // so it never goes full screen either (the green button and ⌃⌘F fill the screen instead, as Fill does).
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .fullScreenNone]
        let tb = NSToolbar(identifier: "Merum")
        tb.delegate = self
        tb.displayMode = .iconOnly
        // View > Customize Toolbar… and the bar's right-click menu, as Apple Notes, Finder and Copia (his recording
        // 2026-11-26: the buttons moved and chosen by him, only what Merum itself needs); the choice is kept by AppKit.
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        w.toolbar = tb
        w.toolbarStyle = .unified
        applyMinimum()
        // The person's size and place, for good, as AppKit keeps them (with the system's tiling state, so a window left
        // in a tiled half comes back in it, and leaving the tile still gives back the size from before it); the first
        // time, the default size centred.
        if !w.setFrameUsingName("Merum Window") {
            w.setFrame(Self.firstFrame(on: w.screen ?? NSScreen.main, minimum: w.minSize), display: false)
            split.splitView.setPosition(Self.sidebarDefault, ofDividerAt: 0)
        }
        fitOnScreen()
        w.setFrameAutosaveName("Merum Window")

        list.onOpen = { [weak self] n in self?.open(n, focus: false) }
        list.onFocusEditor = { [weak self] in self?.focusEditor() }
        editor.onEdited = { [weak self] n in self?.edited(n) }
        editor.onNoteCreated = { [weak self] n in
            guard let self else { return }
            self.list.openID = n.id
            self.list.reload()
            self.updateTitle()
        }
        library.history.reveal = { [weak self] note, range in
            guard let self else { return }
            if self.library.lastOpen != note.id || self.editor.current?.note !== note { self.open(note, focus: false) }
            if let range { self.editor.select(range) }
        }
        NotificationCenter.default.addObserver(forName: Library.didChange, object: library, queue: nil) { [weak self] n in
            let change = n.userInfo?[Library.changeKey] as? Library.Change
            MainActor.assumeIsolated { self?.changed(change) }
        }
        known = Set(library.notes.map(\.id))
        editor.observeStorages()
        let first = library.lastOpen.flatMap(library.note(id:))
        list.openID = first?.id
        _ = list.view
        list.reload()
        editor.show(first, focus: true)
        restoreCaret()
        updateTitle()
        applyLevel()
    }
    required init?(coder: NSCoder) { fatalError() }

    var current: Note? { editor.current?.note }

    // MARK: library changes

    private func changed(_ change: Library.Change?) {
        switch change {
        case .list?, nil:
            let ids = Set(library.notes.map(\.id))
            editor.forget(known.subtracting(ids))
            known = ids
            editor.observeStorages()
            var open = library.lastOpen.flatMap(library.note(id:))
            if open == nil, let first = library.notes.first, !editor.isAdopting {
                // Notes came back with none open (⌘Z of deleting them all): the first is shown.
                library.lastOpen = first.id
                open = first
            }
            if editor.current?.note !== open || list.openID != open?.id {
                let focused = window?.firstResponder === editor.textView
                list.openID = open?.id
                editor.show(open, focus: focused)
            }
            list.reload()
            updateTitle()
            app?.menus.refreshNotes()
        case .title(let n)?:
            list.reloadTitle(of: n)
            if n === current { updateTitle() }
            app?.menus.refreshNotes()
        case .settings?:
            editor.textSizeChanged()
        case .text(let n, _, _)?:
            list.reloadTitle(of: n)
            if n === current { editor.recount(after: 0.5) }
        }
    }

    func updateTitle() {
        let t = current.map { Self.shown($0.title) } ?? "Merum"
        if window?.title != t { window?.title = t }
    }

    /// A name as the window's title, a list row and the Window menu show it: whole up to 300 characters, else its
    /// first 300 and «…». A name is whatever was pasted into the rename field, and the title bar (SwiftUI on macOS 26)
    /// and the rows measure the whole string at every layout pass: an 85,000-character name held the main thread
    /// 0.5-5 s on each one (the monkey test, 2026-11-26). No row or title bar is wide enough for more than about 300.
    static func shown(_ name: String) -> String {
        name.utf8.count <= 1200 || name.count <= 300 ? name : String(name.prefix(300)) + "…"
    }

    // MARK: opening notes

    /// Shows a note; the one left, if it was left empty and never renamed, goes (Library.leave).
    func open(_ note: Note, focus: Bool) {
        let old = current
        library.lastOpen = note.id
        list.openID = note.id
        editor.show(note, focus: focus)
        list.selectOpen()
        updateTitle()
        if let t = editor.textView { list.revealMatch(in: t) }
        if let old, old !== note { library.leave(old) }
    }

    func focusEditor() {
        if let t = editor.textView { window?.makeFirstResponder(t) }
    }

    /// The caret of the note open at the last quit, put back at launch.
    private func restoreCaret() {
        let d = UserDefaults.standard
        guard let n = current, d.string(forKey: "caretNote") == n.id.uuidString else { return }
        let r = NSRange(location: d.integer(forKey: "caretLocation"), length: d.integer(forKey: "caretLength"))
        if NSMaxRange(r) <= n.storage.length { editor.select(r) }
    }

    func saveCaret() {
        let d = UserDefaults.standard
        guard let n = current, let r = editor.caret else { d.removeObject(forKey: "caretNote"); return }
        d.set(n.id.uuidString, forKey: "caretNote")
        d.set(r.location, forKey: "caretLocation")
        d.set(r.length, forKey: "caretLength")
    }

    // MARK: Keep on Top

    static var keepOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepOnTop") }
    }

    /// Kept on top: the window floats over every other app's windows, all the time it is shown. (Until 2026-11-25 it
    /// floated only while another app was in front and dropped to the normal level while Merum was: each switch of
    /// level moved the window out of the window server's order and back, and he saw it blink, «исчезает на секунду».)
    func applyLevel() {
        window?.level = Self.keepOnTop ? .floating : .normal
    }

    @objc func toggleKeepOnTop(_ sender: Any?) {
        Self.keepOnTop.toggle()
        applyLevel()
        app?.settings?.refresh()
    }

    // MARK: commands

    @objc func newNote(_ sender: Any?) {
        if let old = current, old.length == 0, !old.renamed, !library.pastes.contains(where: { $0.note === old }) {
            // The note open is already a new, empty one: it stays the one written in when it is the only note; else it
            // goes and the new one takes the next free name, last in the manual order.
            if library.notes.count == 1 { focusEditor(); return }
            library.leave(old)
        }
        let n = library.newNote()
        open(n, focus: true)
    }

    @objc func saveNote(_ sender: Any?) {
        guard let n = current, let w = window else { return }
        Saver.save(n, from: w)
    }

    @objc func showNotesList(_ sender: Any?) {
        if sidebar.isCollapsed { sidebar.animator().isCollapsed = false }
        window?.makeFirstResponder(list.table)
        if list.table.selectedRowIndexes.isEmpty { list.selectOpen() }
    }

    @objc func openNoteAtIndex(_ sender: NSMenuItem) {
        let i = sender.tag
        guard i < library.notes.count else { return }
        open(library.notes[i], focus: true)
    }

    @objc func renameNote(_ sender: Any?) {
        guard let n = current else { return }
        if sidebar.isCollapsed { sidebar.isCollapsed = false }
        list.beginRename(n)
    }

    @objc func zoomIn(_ sender: Any?) { stepTextSize(+1) }
    @objc func zoomOut(_ sender: Any?) { stepTextSize(-1) }
    @objc func actualSize(_ sender: Any?) { library.textSize = 100 }

    private func stepTextSize(_ d: Int) {
        let steps = Library.textSizes
        guard let i = steps.firstIndex(of: library.textSize) else { library.textSize = 100; return }
        library.textSize = steps[max(0, min(steps.count - 1, i + d))]
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let s = Library.Sort(rawValue: sender.representedObject as? String ?? "") else { return }
        library.sort = s
    }

    @objc func sortOrder(_ sender: NSMenuItem) {
        // Tag 1: newest first, Descending. Tag 0: oldest first, Ascending.
        library.ascending = sender.tag == 0
    }

    /// Find from the list or anywhere else in the window: the open note's find bar.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard let t = editor.textView else { return }
        window?.makeFirstResponder(t)
        t.performFindPanelAction(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pinNotes(_:)):
            item.title = pinTitle
            return !pinTargets.isEmpty
        case #selector(saveNote(_:)), #selector(renameNote(_:)), #selector(deleteOpenNote(_:)):
            return current != nil
        case #selector(openNoteAtIndex(_:)):
            item.state = item.tag < library.notes.count && library.notes[item.tag] === current ? .on : .off
            return item.tag < library.notes.count
        case #selector(zoomIn(_:)): return library.textSize < Library.textSizes.last!
        case #selector(zoomOut(_:)): return library.textSize > Library.textSizes.first!
        case #selector(actualSize(_:)): return library.textSize != 100
        case #selector(sortBy(_:)):
            item.state = library.sort.rawValue == item.representedObject as? String ? .on : .off
            return true
        case #selector(sortOrder(_:)):
            let s = library.sort
            item.isHidden = s == .manual || (s == .title) != (item.representedObject as? String == "title")
            item.state = (item.tag == 0) == library.ascending ? .on : .off
            return s != .manual
        case #selector(toggleKeepOnTop(_:)):
            item.state = Self.keepOnTop ? .on : .off
            return true
        case #selector(showNotesList(_:)):
            return true
        case #selector(searchNotes(_:)):
            return searchItem != nil   // Search taken out of the bar by Customize Toolbar…
        case #selector(performFindPanelAction(_:)):
            return editor.textView?.validateMenuItem(item) ?? false
        default:
            return true
        }
    }

    // MARK: window

    func windowDidResize(_ notification: Notification) { fitSidebar() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        app?.hide()
        return false
    }

    /// The minimum measured again (Sizer) and applied: to the note's split item, so that the sidebar gives up room
    /// before the note does, and to the window, the same with the sidebar shown or hidden.
    func applyMinimum() {
        guard let w = window else { return }
        defer { fitSidebar() }
        let need = sizer.measure()
        editorMin = need.editor
        minHeight = need.height
        split.splitViewItems.last?.minimumThickness = editorMin
        w.minSize = minimumSize
        // A window smaller than the new minimum (a button added, an old saved frame) grows to it, kept on its screen.
        if w.frame.width < w.minSize.width - 0.5 || w.frame.height < w.minSize.height - 0.5 { fitOnScreen() }
    }

    /// The sidebar never wider than the window leaves beside the narrowest whole note. AppKit opens a hidden sidebar
    /// (⌃⌘S, the toolbar's button, or the peek when the pointer rests at the window's edge on macOS 26) at the width it
    /// had, and where the window no longer had room for that width beside the note it grew the window instead: by the
    /// width of the sidebar (his recording 2026-11-27), and during the peek, from inside AppKit's own layout, into a
    /// crash (-[NSSplitView _cancelProactivePeek] on a null pointer, the monkey test 2026-11-27). Kept within the room
    /// on every change of the window's size, the sidebar comes back as wide as it fits, the window never moves.
    func fitSidebar() {
        guard let w = window else { return }
        let room = (w.contentLayoutRect.width - editorMin).rounded(.down)
        let most = max(Self.sidebarMin, min(Self.sidebarMax, room))
        if sidebar.maximumThickness != most { sidebar.maximumThickness = most }
    }

    /// The frame kept within what it must be: never under the minimum, never off its screen. An autosaved frame from a
    /// larger screen or another display arrangement is brought into the visible area here, before the window shows.
    func fitOnScreen() {
        guard let w = window, let screen = w.screen ?? NSScreen.main else { return }
        // A frame inside the screen is left as it is: the window manager's tiles reach a few points past the usable area
        // (into the Dock's margin: 805 pt high where 799 are usable on a 1440 x 900 screen, macOS 26).
        if screen.frame.contains(w.frame) && w.frame.width >= w.minSize.width - 0.5 && w.frame.height >= w.minSize.height - 0.5 { return }
        let v = screen.visibleFrame
        var f = w.frame
        f.size.width = min(max(f.width, w.minSize.width), max(v.width, w.minSize.width))
        f.size.height = min(max(f.height, w.minSize.height), max(v.height, w.minSize.height))
        f.origin.x = min(max(f.minX, v.minX), max(v.maxX - f.width, v.minX))
        f.origin.y = min(max(f.minY, v.minY), max(v.maxY - f.height, v.minY))
        if f != w.frame { w.setFrame(f, display: w.isVisible) }
    }

    /// The first window: the default size, cut to the screen's visible area less a margin on each side where the screen is
    /// smaller than it (never below the minimum), centred as NSWindow.center() places it: a third of the way down.
    static func firstFrame(on screen: NSScreen?, minimum: NSSize) -> NSRect {
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height)
        // The margin a tiled window keeps from the screen's edges on macOS 26, so the first window never touches them.
        let margin: CGFloat = 8
        let w = max(minimum.width, min(defaultSize.width, v.width - 2 * margin))
        let h = max(minimum.height, min(defaultSize.height, v.height - 2 * margin))
        let x = (v.midX - w / 2).rounded()
        let y = (v.minY + (v.height - h) * 2 / 3).rounded()
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// The rename field, the search field and the find bar's field all edit in this one (FieldEditor: why).
    private let fieldEditor: FieldEditor = { FieldEditor.guardAppKitFields(); return FieldEditor.make() }()
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { fieldEditor }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let t = window.firstResponder as? NSTextView, t.isFieldEditor { return fieldUndo }
        return library.history.undoManager
    }

    // MARK: toolbar
    // As Apple Notes and Copia (his recording 2026-11-25: «создать новую заметку… Шэр, отправить… три точки… поиск
    // должен быть по-любому»): the sidebar button over the list; New Note, Share, the «…» menu and Search over the note.
    // Every command here is also in the menu bar (HIG: the toolbar is never the only way).

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .newNote, .flexibleSpace, .share, .more, .search]
    }
    /// The palette: the default buttons and the «…» menu's note commands, each one click instead of two.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .newNote, .share, .more, .search,
         .pin, .rename, .findInNote, .deleteNote, .space, .flexibleSpace]
    }

    /// The buttons changed (Customize Toolbar…): the minimum is measured again once the bar has settled.
    func toolbarWillAddItem(_ notification: Notification) { remeasureSoon(notification) }

    private func remeasureSoon(_ n: Notification) {
        guard (n.object as? NSToolbar) === window?.toolbar, !remeasuring else { return }
        remeasuring = true   // one measure for the many items a bar adds at once
        DispatchQueue.main.async { [weak self] in self?.remeasuring = false; self?.applyMinimum() }
    }
    private var remeasuring = false

    func toolbarDidRemoveItem(_ notification: Notification) {
        remeasureSoon(notification)
        // Search taken out of the bar: its filter goes with it, or the list stays cut by a query nobody sees.
        guard let item = notification.userInfo?["item"] as? NSToolbarItem, item.itemIdentifier == .search else { return }
        searchItem?.searchField.stringValue = ""
        list.search("")
        searchItem = nil
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .pin:
            let t = pinTitle
            item.label = t; item.toolTip = t
            item.image = NSImage(systemSymbolName: t.hasPrefix("Unpin") ? "pin.slash" : "pin", accessibilityDescription: t)
            return !pinTargets.isEmpty
        case .rename, .deleteNote: return current != nil
        case .findInNote: return editor.textView != nil
        default: return true
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ title: String, _ symbol: String, _ action: Selector,
                        tag: Int = 0) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title; item.paletteLabel = title; item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isBordered = true
        item.target = self
        item.action = action
        item.tag = tag
        return item
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .newNote:
            return button(id, "New Note", "square.and.pencil", #selector(newNote(_:)))
        case .pin:
            let item = button(id, "Pin", "pin", #selector(pinNotes(_:)))
            item.paletteLabel = "Pin"
            return item
        case .rename:
            return button(id, "Rename", "character.cursor.ibeam", #selector(renameNote(_:)))
        case .findInNote:
            return button(id, "Find in Note", "text.magnifyingglass", #selector(performFindPanelAction(_:)),
                          tag: NSTextFinder.Action.showFindInterface.rawValue)
        case .deleteNote:
            return button(id, "Delete Note", "trash", #selector(deleteOpenNote(_:)))
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"; item.paletteLabel = "Share"; item.toolTip = "Share"
            item.delegate = self
            return item
        case .more:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "More"; item.paletteLabel = "More"; item.toolTip = "More"
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            item.showsIndicator = false
            // The palette of Customize Toolbar… asks for its own copy (flag false): it gets a menu of its own, as one
            // menu cannot be two items' at once and the bar's «…» would lose its own.
            item.menu = flag ? moreMenu() : NSMenu()
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search"; item.paletteLabel = "Search"
            item.searchField.placeholderString = "Search"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.delegate = self
            // Only the bar's own field is the search: the palette's copy (flag false) goes when the sheet closes, and
            // kept here it left ⌥⌘F and the list's filter pointing at a field nobody sees.
            if flag { searchItem = item }
            return item
        default:
            return nil
        }
    }

    /// The «…» menu, as the iPhone's: Find in Note; Pin, Rename, Save…, Sort By; Delete Note. Every command in it is
    /// also in the menu bar. (The counts the iPhone shows in it are the line under the Mac's text, always in sight.)
    let more = NSMenu()

    private func moreMenu() -> NSMenu {
        more.delegate = self
        more.autoenablesItems = true
        return more
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === more else { return }
        menu.removeAllItems()
        func add(_ t: String, _ a: Selector?, tag: Int = 0) {
            let it = NSMenuItem(title: t, action: a, keyEquivalent: "")
            it.target = a == nil ? nil : self
            it.tag = tag
            menu.addItem(it)
        }
        add("Find in Note", #selector(performFindPanelAction(_:)), tag: NSTextFinder.Action.showFindInterface.rawValue)
        menu.addItem(.separator())
        add(pinTitle, #selector(pinNotes(_:)))
        add("Rename", #selector(renameNote(_:)))
        add("Save…", #selector(saveNote(_:)))
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sort.submenu = Menus.sortMenu()
        menu.addItem(sort)
        menu.addItem(.separator())
        add("Delete Note", #selector(deleteOpenNote(_:)))
    }

    /// The open note's row follows its typing (date edited, the beginning of the text) a moment after a pause.
    private var rowRefresh: DispatchWorkItem?
    private func edited(_ n: Note) {
        rowRefresh?.cancel()
        let w = DispatchWorkItem { [weak self, weak n] in
            MainActor.assumeIsolated { if let n { self?.list.reloadTitle(of: n) } }
        }
        rowRefresh = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// What Pin Note acts on: the notes selected in the list while it has the keys (one or several), else the note open.
    private var pinTargets: [Note] {
        if window?.firstResponder === list.table, !list.selectedNotes.isEmpty { return list.selectedNotes }
        return current.map { [$0] } ?? []
    }
    var pinTitle: String { list.pinTitle(pinTargets) }

    /// File > Pin Note / Unpin Note(s), the list's right-click menu, the «…» menu: one undo step (the core's).
    @objc func pinNotes(_ sender: Any?) { list.pin(pinTargets) }

    /// The note open, deleted as Delete does in the list (the «…» menu's Delete Note).
    @objc func deleteOpenNote(_ sender: Any?) {
        guard let n = current else { return }
        library.delete([n])
    }

    func items(for item: NSSharingServicePickerToolbarItem) -> [Any] {
        let picked = list.selectedNotes.count > 1 ? list.selectedNotes : current.map { [$0] } ?? []
        let texts = picked.map { $0.storage.string }.filter { !$0.isEmpty }
        return texts.isEmpty ? [] : [texts.joined(separator: "\n")]
    }

    @objc func searchChanged(_ field: NSSearchField) { list.search(field.stringValue) }

    #if TRIALS
    /// Whether the search ⌥⌘F begins is the one in the window's bar.
    var searchIsInBar: Bool { searchItem.map { $0.searchField.window === window && window?.toolbar?.items.contains($0) == true } ?? false }
    #endif

    /// Edit > Find > Note List Search… (⌥⌘F, as Apple Notes): the search field, the sidebar shown for its results.
    @objc func searchNotes(_ sender: Any?) {
        if sidebar.isCollapsed { sidebar.animator().isCollapsed = false }
        searchItem?.beginSearchInteraction()
    }
}

/// The main window. AppKit trims a window that reaches past the screen's usable area each time it is ordered in, and a
/// tiled half does reach past it (the window manager's tile is a few points taller than the visible frame): on every
/// hot-key show the window came up those points short and the window manager put it back ~0.35 s later, measured frame
/// by frame on macOS 26.6 (805 → 799 → 805 pt). A frame that lies within the screen is left alone; one that leaves the
/// screen is still brought back as AppKit does it.
final class MerumWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if let s = screen ?? self.screen, s.frame.contains(frameRect) { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The window's field editor (rename, search, the find bar): AppKit's own, except that a paste or a drop puts in the
/// pasteboard's plain string as typed text. AppKit's paste turns the bidi embedding and override characters of a plain
/// string (U+202A-U+202E) into nested NSWritingDirection attributes; on macOS 26, a run nested 12 deep right after a
/// shallower one makes CoreFoundation's bidi pass trap («Size of noLongerSeeControlChars has exceeded allowed control
/// character limit») and the app dies, in TextKit 1 and 2 alike, TextEdit too. Fourteen characters are enough:
/// U+202E, nine U+202D, U+20DD, two U+202D, «;» (found by the monkey test on 26.6.2, 2026-11-26; measured in a test
/// machine: the same text typed or inserted as a string lays out fine). Inserted as a string, every character stays as
/// it was pasted, the controls included; only the attributes AppKit would have made are not made.
final class FieldEditor: NSTextView {
    static func make() -> FieldEditor {
        // TextKit 1, as the notes' views are (editor.swift).
        let f = FieldEditor(usingTextLayoutManager: false)
        f.isFieldEditor = true
        return f
    }

    override func paste(_ sender: Any?) { _ = insertPlain(from: Clipboard.board) }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    /// Drops and Services land here too, with the selection already where the text goes.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        insertPlain(from: pboard) || super.readSelection(from: pboard, type: type)
    }

    /// The one text view of the window that is AppKit's own, the find bar's field (NSFindPatternFieldEditor, which the
    /// window's delegate is not asked for), keeps AppKit's paste; the attributes that paste makes are taken off again
    /// before anything lays them out. There the bidi controls of a pasted query are lost (AppKit took them out of the
    /// string); the app lives. Notes never carry those attributes (their paste is the core's).
    static func guardAppKitFields() {
        NotificationCenter.default.addObserver(forName: NSTextStorage.willProcessEditingNotification, object: nil, queue: nil) { n in
            guard let s = n.object as? NSTextStorage, s.editedMask.contains(.editedAttributes) || s.editedMask.contains(.editedCharacters),
                  s.editedRange.length > 0, NSMaxRange(s.editedRange) <= s.length else { return }
            MainActor.assumeIsolated {
                guard !s.layoutManagers.contains(where: { $0.firstTextView is NoteTextView }) else { return }
                s.removeAttribute(.writingDirection, range: s.editedRange)
                // Typed text, and the find bar's own paste, get the same limit, right after the edit (characters cannot
                // change here).
                guard s.length > pasteLimit else { return }
                DispatchQueue.main.async {
                    guard let t = NSApp.keyWindow?.firstResponder as? NSTextView, t.isFieldEditor,
                          t.textStorage === s, s.length > pasteLimit else { return }
                    let keep = (capped(s.string) as NSString).length
                    let cut = NSRange(location: keep, length: s.length - keep)
                    if t.shouldChangeText(in: cut, replacementString: "") { s.replaceCharacters(in: cut, with: ""); t.didChangeText() }
                }
            }
        }
    }

    /// A field holds at most this many characters (a name, a query): the rest of a long paste is left out, typing past it
    /// is cut back. On macOS 26 the toolbar and the find bar measure a field's whole string on every layout pass (SwiftUI): 85,000
    /// pasted characters held the main thread 1-3 s again and again in the monkey test.
    static let pasteLimit = 1_000
    static func capped(_ s: String) -> String { s.utf16.count <= pasteLimit ? s : String(s.prefix(pasteLimit)) }

    private func insertPlain(from pboard: NSPasteboard) -> Bool {
        guard isEditable, let s = pboard.string(forType: .string) else { return false }
        insertText(Self.capped(s), replacementRange: selectedRange())
        return true
    }
}
