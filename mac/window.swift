// The one window: the notes list in a sidebar and the open note beside it, a toolbar with the sidebar button and New
// Note (Apple Notes' compose button), the open note's name as the window's title. Its size and place are the person's,
// kept for good. The red button and ⌘W hide it as the hot key does (App.hide); the app keeps running for the key.
import AppKit

extension NSToolbarItem.Identifier {
    static let newNote = NSToolbarItem.Identifier("newNote")
    static let share = NSToolbarItem.Identifier("share")
    static let more = NSToolbarItem.Identifier("more")
    static let search = NSToolbarItem.Identifier("search")
}

@MainActor final class MainWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                   NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate, NSMenuDelegate {
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
    /// The smallest window: every toolbar button in the bar, never in the » overflow, and five notes in the list with
    /// nothing cut (his recordings 2026-11-25: Apple Notes «обрезает слишком сильно»; at the minimum nothing cut, no
    /// scroll bar where the content fits). Measured on macOS 27 with the longest default name as the title: the buttons
    /// need 328 pt beside the sidebar (overflow began at a 510 pt window with the sidebar at 182); the editor keeps
    /// 32 pt more for larger system text settings, 360. Height: the toolbar (52) and five two-line rows (5 x 56) = 332.
    /// A width at which the toolbar still overflows (another setting, a new macOS) raises the minimum on the spot
    /// (windowDidResize).
    static var minSize: NSSize { NSSize(width: sidebarMin + editorMin, height: 332) }
    static var editorMin: CGFloat = 360
    /// The first window, «как открывается текст»: TextEdit's new-window measure, his TextEdit set to 98 characters by
    /// 32 lines, in this app's font (13 pt San Francisco: 6.64 pt a character, the mean of English and Russian text;
    /// 16 pt lines): text 651 x 512 pt, with the text's insets, the toolbar and the counts line an editor of 685 x 606,
    /// and the sidebar at a third of its range (182 + (360 - 182) / 3 = 241). 926 x 606 pt, about 54 % x 56 % of a
    /// 1728 x 1084 pt screen.
    static let defaultSize = NSSize(width: 926, height: 606)
    static let sidebarDefault: CGFloat = 241

    init(library: Library) {
        self.library = library
        list = NotesListController(library: library)
        editor = EditorController(library: library)
        sidebar = NSSplitViewItem(sidebarWithViewController: list)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init(window: w)

        sidebar.minimumThickness = Self.sidebarMin
        sidebar.maximumThickness = Self.sidebarMax
        sidebar.canCollapse = true
        let main = NSSplitViewItem(viewController: editor)
        main.minimumThickness = Self.editorMin
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(main)
        split.splitView.autosaveName = "Merum Sidebar"

        w.contentViewController = split
        w.delegate = self
        w.isReleasedWhenClosed = false
        // Nothing in Saved Application State: the window comes back by the app's own settings, not by restoration.
        w.isRestorable = false
        w.tabbingMode = .disallowed
        w.minSize = Self.minSize
        w.titleVisibility = .visible
        // Over every window of the Space it is called to, full-screen apps included; it never takes a Space of its own.
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let tb = NSToolbar(identifier: "Merum")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        w.toolbarStyle = .unified
        // The person's size and place, for good; the first time, 760 x 520 centred (the split view would size it
        // to its parts' minimums).
        if !w.setFrameUsingName("Merum Window") {
            w.setContentSize(Self.defaultSize)
            w.center()
            split.splitView.setPosition(Self.sidebarDefault, ofDividerAt: 0)
        }
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
        let t = current?.title ?? "Merum"
        if window?.title != t { window?.title = t }
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
        case #selector(performFindPanelAction(_:)):
            return editor.textView?.validateMenuItem(item) ?? false
        default:
            return true
        }
    }

    // MARK: window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        app?.hide()
        return false
    }

    /// Never a toolbar button in the » overflow: a width at which one went there becomes the minimum.
    func windowDidResize(_ notification: Notification) {
        guard let w = window, let tb = w.toolbar else { return }
        let spacers: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
        let wanted = Set(tb.items.map(\.itemIdentifier)).subtracting(spacers)
        let shown = Set((tb.visibleItems ?? []).map(\.itemIdentifier)).subtracting(spacers)
        guard !wanted.isSubset(of: shown), w.frame.width + 10 > w.minSize.width else { return }
        w.minSize.width = w.frame.width + 10
        var f = w.frame; f.size.width = w.minSize.width
        w.setFrame(f, display: true)
    }

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
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .newNote:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "New Note"; item.paletteLabel = "New Note"; item.toolTip = "New Note"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Note")
            item.isBordered = true
            item.target = self
            item.action = #selector(newNote(_:))
            return item
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
            item.menu = moreMenu()
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search"; item.paletteLabel = "Search"
            item.searchField.placeholderString = "Search"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.delegate = self
            searchItem = item
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

    /// Edit > Find > Note List Search… (⌥⌘F, as Apple Notes): the search field, the sidebar shown for its results.
    @objc func searchNotes(_ sender: Any?) {
        if sidebar.isCollapsed { sidebar.animator().isCollapsed = false }
        searchItem?.beginSearchInteraction()
    }
}
