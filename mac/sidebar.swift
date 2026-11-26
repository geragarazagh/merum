// The notes list in the sidebar: names only, in the library's sort, in the source-list style that takes the person's
// accent and highlight colours. As in Apple Notes and Finder: a click opens a note, ⌘-click and ⇧-click and ⌘A select
// several, Delete or ⌘⌫ deletes the selected notes with no question (⌘Z brings them back), Return renames in place,
// drag reorders in the manual sort. Unlike Apple Notes, Esc and a click on empty space clear a multi-selection back to
// the open note; ⌘C copies the selected notes' texts as plain text, joined as Copia joins several items (one line
// break between, in the order they were picked).
import AppKit

extension NSPasteboard.PasteboardType {
    /// A note dragged inside the list.
    static let merumNote = NSPasteboard.PasteboardType("com.geragaraza.merum.note")
}

@MainActor final class NotesListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
                                            NSPasteboardItemDataProvider, NSMenuDelegate {
    let library: Library
    let table = NotesTable()
    private let scroll = NSScrollView()
    /// The note shown in the editor; its row is the selection whenever only one row is selected.
    var openID: UUID?
    /// A single row chosen by the person.
    var onOpen: ((Note) -> Void)?
    var onFocusEditor: (() -> Void)?
    private var quiet = false
    /// The selected notes in the order they were picked (⌘C keeps it).
    var picked: [UUID] = []
    private var renaming: (note: Note, field: NSTextField)?

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        // Two lines a note, as Apple Notes' list: its row pitch on macOS 27 is 56 pt (his recording 2026-11-25).
        table.rowSizeStyle = .custom
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.controller = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        // The group headers scroll with the rows: nothing stays pinned while the list rubber-bands (his rule).
        table.floatsGroupRows = false
        table.registerForDraggedTypes([.merumNote])
        table.draggingDestinationFeedbackStyle = .gap
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setAccessibilityLabel("Notes")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        view = scroll
    }

    /// The rows: every note in the library's sort, or while a search is typed only those whose name or text holds it.
    var notes: [Note] {
        guard let found = matches else { return library.notes }
        return library.notes.filter { found.contains($0.id) }
    }

    // MARK: search (the toolbar's search field, Edit > Find > Note List Search…)

    /// nil: no search. The ids of the notes that match, found on another thread.
    private var matches: Set<UUID>?
    private(set) var query = ""
    private var generation = 0
    private static let searchQueue = DispatchQueue(label: "merum.search", qos: .userInitiated)

    /// Names and texts, case- and diacritic-insensitive, as Apple Notes' search; a ten-million-character note takes
    /// about a third of a second, so the texts are searched off the main thread on copies and the list follows.
    func search(_ q: String) {
        query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        guard !query.isEmpty else { matches = nil; reload(); return }
        let needle = query
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // Immutable copies (NSString snapshots), read only on the search queue.
        nonisolated(unsafe) let items = library.notes.map { ($0.id, $0.title, $0.textSnapshot) }
        Self.searchQueue.async { [weak self] in
            var found = Set<UUID>()
            for (id, title, text) in items {
                if title.range(of: needle, options: opts) != nil || text.range(of: needle, options: opts).location != NSNotFound { found.insert(id) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.matches = found
                    self.reload()
                }
            }
        }
    }

    /// After a note was opened from a search: its first match selected and shown, as Notes shows what was searched.
    func revealMatch(in t: NSTextView) {
        guard !query.isEmpty else { return }
        let r = (t.string as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        guard r.location != NSNotFound else { return }
        t.setSelectedRange(r)
        t.scrollRangeToVisible(r)
        t.showFindIndicator(for: r)
    }

    // MARK: data

    // MARK: rows: the notes, and while some are pinned a «Pinned» group first and a «Notes» group after it (Apple Notes)

    enum Row {
        case header(String), note(Note)
        var note: Note? { if case .note(let n) = self { return n }; return nil }
        var key: String { switch self { case .header(let t): "h:" + t; case .note(let n): n.id.uuidString } }
    }
    private(set) var rows: [Row] = []

    private func buildRows() -> [Row] {
        let list = notes
        let pinned = list.filter(\.pinned)
        guard !pinned.isEmpty else { return list.map { .note($0) } }
        var r: [Row] = [.header("Pinned")] + pinned.map { .note($0) }
        let rest = list.filter { !$0.pinned }
        if !rest.isEmpty { r += [.header("Notes")] + rest.map { .note($0) } }
        return r
    }

    func note(at row: Int) -> Note? { row >= 0 && row < rows.count ? rows[row].note : nil }
    func row(of id: UUID) -> Int? { rows.firstIndex { $0.note?.id == id } }
    /// A table row as a place in the library's list (what Library.move takes): the notes above it.
    private func listIndex(_ row: Int) -> Int { rows.prefix(max(0, min(row, rows.count))).filter { $0.note != nil }.count }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { note(at: row) == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { note(at: row) != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let n = note(at: row) else {
            let hid = NSUserInterfaceItemIdentifier("header")
            let h = tableView.makeView(withIdentifier: hid, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = hid
                let f = NSTextField(labelWithString: "")
                f.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                f.textColor = .secondaryLabelColor
                f.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(f)
                c.textField = f
                NSLayoutConstraint.activate([f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                             f.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                return c
            }()
            if case .header(let t) = rows[row] { h.textField?.stringValue = t }
            return h
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NoteCell ?? {
            let c = NoteCell()
            c.identifier = id
            c.textField?.delegate = self
            return c
        }()
        cell.show(n)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        note(at: row) == nil ? NoteCell.headerHeight : NoteCell.height
    }

    func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool { true }
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { note(at: row)?.title }

    /// The list changed (notes came, went, moved or were renamed): rows again, the selection kept by note.
    func reload() {
        if dragging { reloadWaiting = true; return }
        if let r = renaming, !library.contains(r.note) { renaming = nil }
        let selected = picked
        quiet = true
        rows = buildRows()
        update(to: rows.map(\.key))
        var sel = IndexSet(selected.compactMap { row(of: $0) })
        if sel.count <= 1, let open = openRow { sel = [open] }
        table.selectRowIndexes(sel, byExtendingSelection: false)
        quiet = false
        syncPicked()
        if let open = openRow, sel.count == 1 { table.scrollRowToVisible(open) }
    }

    /// The rows the table shows now, by note.
    private var shownIDs: [String] = []

    /// Rows that come and go and move do so with the table's own animations (a new note fades in where it lands, a
    /// deleted one fades out, a moved one slides), as Notes' and Reminders' lists do; anything else reloads.
    private func update(to new: [String]) {
        let old = shownIDs
        shownIDs = new
        guard !old.isEmpty, old != new, view.window?.isVisible == true else { table.reloadData(); return }
        let oldSet = Set(old), newSet = Set(new)
        NSAnimationContext.runAnimationGroup { _ in
            table.beginUpdates()
            if oldSet == newSet {
                var cur = old
                for (to, id) in new.enumerated() where cur[to] != id {
                    let from = cur.firstIndex(of: id)!
                    table.moveRow(at: from, to: to)
                    cur.remove(at: from); cur.insert(id, at: to)
                }
            } else {
                let removed = IndexSet(old.enumerated().filter { !newSet.contains($0.element) }.map(\.offset))
                let kept = old.filter { newSet.contains($0) }
                if kept != new.filter({ oldSet.contains($0) }) {
                    table.endUpdates(); table.reloadData(); return
                }
                table.removeRows(at: removed, withAnimation: .effectFade)
                let added = IndexSet(new.enumerated().filter { !oldSet.contains($0.element) }.map(\.offset))
                table.insertRows(at: added, withAnimation: .effectFade)
            }
            table.endUpdates()
        }
        // Names may have changed under rows that stayed.
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<new.count), columnIndexes: [0])
    }

    /// One note's row again: name, date edited, the beginning of the text (renamed, typed in, changed elsewhere).
    func reloadTitle(of note: Note) {
        guard let row = row(of: note.id), renaming?.note !== note else { return }
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteCell)?.show(note)
    }

    var openRow: Int? { openID.flatMap { row(of: $0) } }

    /// The open note alone selected (Esc, a click on empty space, a note opened from elsewhere).
    func selectOpen() {
        quiet = true
        if let r = openRow {
            table.selectRowIndexes([r], byExtendingSelection: false)
            table.scrollRowToVisible(r)
        } else {
            table.deselectAll(nil)
        }
        quiet = false
        syncPicked()
    }

    private func syncPicked() {
        let now = table.selectedRowIndexes.compactMap { note(at: $0)?.id }
        picked.removeAll { !now.contains($0) }
        for id in now where !picked.contains(id) { picked.append(id) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        syncPicked()
        guard !quiet else { return }
        let rows = table.selectedRowIndexes
        if rows.isEmpty {
            // ⌘-click on the last selected row: the open note stays selected, as the editor still shows it.
            selectOpen()
        } else if rows.count == 1, let r = rows.first, let n = note(at: r), n.id != openID {
            onOpen?(n)
        }
    }

    var selectedNotes: [Note] {
        picked.compactMap { id in notes.first { $0.id == id } }
    }

    // MARK: commands

    func deleteSelected() {
        let list = selectedNotes
        guard !list.isEmpty else { return }
        picked = []
        library.delete(list)
    }

    /// A click on empty space in the list: back to the open note alone; an open note left empty and never renamed goes
    /// then, as it goes when another note is clicked (his recording 2026-11-25: Apple Notes keeps it there, «плохо»).
    func clickedEmpty() {
        if let id = openID, let n = library.note(id: id), n.length == 0, !n.renamed, library.notes.count > 1,
           !library.pastes.contains(where: { $0.note === n }) {
            library.leave(n)
        } else {
            selectOpen()
        }
    }

    func copySelected() {
        let texts = selectedNotes.map { $0.storage.string }.filter { !$0.isEmpty }
        let pb = Clipboard.board
        pb.clearContents()
        pb.setString(texts.joined(separator: "\n"), forType: .string)
    }

    @objc func doubleClicked() {
        let r = table.clickedRow
        guard let n = note(at: r) else { return }
        beginRename(n)
    }

    /// Rename in place: the name becomes a field, all of it selected; Return or a click elsewhere keeps the new name,
    /// Esc keeps the old one. An empty name gives the note back a default name (the core).
    func beginRename(_ note: Note) {
        guard let row = row(of: note.id) else { return }
        if openID != note.id { onOpen?(note) }
        selectOpen()
        table.scrollRowToVisible(row)
        guard let f = (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
        renaming = (note, f)
        // The row shows a long name cut (MainWindow.shown); the field edits all of it.
        f.stringValue = note.title
        f.isEditable = true
        f.isSelectable = true
        view.window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let r = renaming, control === r.field else { return false }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            r.field.stringValue = MainWindow.shown(r.note.title)
            renaming = nil
            r.field.isEditable = false
            view.window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let r = renaming, obj.object as? NSTextField === r.field else { return }
        renaming = nil
        r.field.isEditable = false
        library.rename(r.note, to: r.field.stringValue)
        r.field.stringValue = MainWindow.shown(r.note.title)
        if view.window?.firstResponder == nil || view.window?.firstResponder === view.window { view.window?.makeFirstResponder(table) }
    }

    var isRenaming: Bool { renaming != nil }

    // MARK: drag

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let n = note(at: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(n.id.uuidString, forType: .merumNote)
        // Dropped into another app (or a note), it is its text; given only when asked, a big note costs nothing to drag.
        item.setDataProvider(self, forTypes: [.string])
        return item
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        MainActor.assumeIsolated {
            guard let s = item.string(forType: .merumNote), let id = UUID(uuidString: s), let n = library.note(id: id) else { return }
            item.setString(n.storage.string, forType: .string)
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // Reordering is the manual sort's, over the whole list: not while a search shows only some notes.
        guard info.draggingSource as? NSTableView === table, library.sort == .manual, matches == nil else { return [] }
        if op == .on || row > rows.count {
            // Over a row: before it from its upper half, after it from its lower half; below the last row: the end.
            let p = tableView.convert(info.draggingLocation, from: nil)
            let to = row >= rows.count ? rows.count : (p.y > tableView.rect(ofRow: row).midY ? row + 1 : row)
            tableView.setDropRow(to, dropOperation: .above)
        }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard library.sort == .manual, matches == nil else { return false }
        let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .merumNote).flatMap(UUID.init(uuidString:)) }
        let moving = notes.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return false }
        // Inside its own group (pinned or not): the core stops a move at the group's edge. Made once the drag session
        // has ended (draggingSession(endedAt:)): the table still clears its drop gap after this returns, and rows that
        // changed under it crashed AppKit (EXC_BAD_ACCESS in NSTableRowHeightData, 2026-11-25 14:09:58 on his Mac).
        pendingMove = (moving, listIndex(row))
        return true
    }

    /// While a row is being dragged the rows stay as they are: a list change arriving then (another device, the empty
    /// note dropped, a move) is applied when the drag has ended.
    private var dragging = false
    private var reloadWaiting = false
    private var pendingMove: ([Note], Int)?

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragging = true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // After the table's own clean-up, on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dragging = false
            if let (moving, to) = self.pendingMove {
                self.pendingMove = nil
                self.library.move(moving.filter(self.library.contains), toIndex: to)
            }
            if self.reloadWaiting { self.reloadWaiting = false; self.reload() }
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard let clicked = note(at: r) else {
            // On empty space: what can be made there, as Finder offers New Folder (his recording: a right click there
            // gave nothing).
            menu.addItem(withTitle: "New Note", action: #selector(MainWindow.newNote(_:)), keyEquivalent: "")
            return
        }
        // A right click on a row outside the selection acts on that row alone, as in Finder.
        if !table.selectedRowIndexes.contains(r) {
            onOpen?(clicked)
            selectOpen()
        }
        let many = table.selectedRowIndexes.count > 1
        // Apple Notes' order: Pin first.
        menu.addItem(withTitle: pinTitle(selectedNotes), action: #selector(pinClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if !many { menu.addItem(withTitle: "Rename", action: #selector(renameClicked), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Copy", action: #selector(copyClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: many ? "Delete Notes" : "Delete Note", action: #selector(deleteClicked), keyEquivalent: "").target = self
    }

    /// Pin Note, Unpin Notes…: unpins when every one of them is pinned, else pins them all (Apple Notes).
    func pinTitle(_ list: [Note]) -> String { History.pinName(!list.allSatisfy(\.pinned) || list.isEmpty, max(1, list.count)) }
    func pin(_ list: [Note]) {
        guard !list.isEmpty else { return }
        library.pin(list, !list.allSatisfy(\.pinned))
    }
    @objc private func pinClicked() { pin(selectedNotes) }

    @objc private func renameClicked() { if let n = selectedNotes.first { beginRename(n) } }
    @objc private func copyClicked() { copySelected() }
    @objc private func deleteClicked() { deleteSelected() }
}

/// The list's keys, as Finder's and Notes' lists have them.
final class NotesTable: NSTableView {
    weak var controller: NotesListController?

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(e.keyCode) {
        case 51 where mods.isEmpty || mods == .command, 117 where mods.isEmpty || mods == .command:   // ⌫ ⌦, ⌘⌫ ⌘⌦
            MainActor.assumeIsolated { controller?.deleteSelected() }
        case 36 where mods.isEmpty, 76 where mods.isEmpty:                       // Return, Enter
            MainActor.assumeIsolated { if let c = controller, let n = c.selectedNotes.first, c.selectedNotes.count == 1 { c.beginRename(n) } }
        case 53 where mods.isEmpty:                           // Esc
            MainActor.assumeIsolated { controller?.selectOpen() }
        case 48 where mods.isEmpty:                           // Tab: into the note
            MainActor.assumeIsolated { controller?.onFocusEditor?() }
        default:
            super.keyDown(with: e)
        }
    }

    /// ⌘A picks every note in the list's order.
    override func selectAll(_ sender: Any?) {
        MainActor.assumeIsolated { controller?.picked = [] }
        super.selectAll(sender)
    }

    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { controller?.selectOpen() } }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if row(at: p) < 0 {
            // A click on empty space: back to the open note alone (Apple Notes would keep the selection).
            MainActor.assumeIsolated { controller?.clickedEmpty() }
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: e)
    }

    @objc func copy(_ sender: Any?) { MainActor.assumeIsolated { controller?.copySelected() } }
    @objc func delete(_ sender: Any?) { MainActor.assumeIsolated { controller?.deleteSelected() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(delete(_:)): return selectedRowIndexes.count > 0
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

/// A note's row, as Apple Notes' list draws one on macOS 27: the name in bold, under it the date edited and the
/// beginning of the text in the secondary colour, each cut with «…» where the width ends. The preview reads only the
/// first few hundred characters, so a ten-million-character note costs what a short one does.
final class NoteCell: NSTableCellView {
    static let height: CGFloat = 56
    static let headerHeight: CGFloat = 28
    private let date = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for f in [title, date, preview] {
            f.lineBreakMode = .byTruncatingTail
            f.cell?.truncatesLastVisibleLine = true
            f.translatesAutoresizingMaskIntoConstraints = false
            f.maximumNumberOfLines = 1
            addSubview(f)
        }
        date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 0),
            date.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            date.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: date.trailingAnchor, constant: 6),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            preview.firstBaselineAnchor.constraint(equalTo: date.firstBaselineAnchor)])
        colours()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ n: Note) {
        textField?.stringValue = MainWindow.shown(n.title)
        textField?.isEditable = false
        date.stringValue = Self.dateText(n.modified)
        preview.stringValue = Self.previewText(n)
    }

    /// On the accent colour of a selected row in a focused list the lines go white, as the system's own rows do.
    override var backgroundStyle: NSView.BackgroundStyle { didSet { colours() } }
    private func colours() {
        let on = backgroundStyle == .emphasized
        textField?.textColor = on ? .alternateSelectedControlTextColor : .labelColor
        date.textColor = on ? .alternateSelectedControlTextColor : .labelColor
        preview.textColor = on ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
    }

    /// The beginning of the text on one line: at most 300 characters read, line breaks and runs of spaces as one.
    static func previewText(_ n: Note) -> String {
        let s = n.storage.mutableString
        let head = s.substring(with: NSRange(location: 0, length: min(300, s.length)))
        return head.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Apple Notes' dates in its list: the time today, Yesterday, the weekday within a week, else the short date, in
    /// the formats of the person's region.
    static func dateText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7, days > 0 {
            return weekday.string(from: d)
        }
        return short.string(from: d)
    }
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE"); return f }()
    private static let short: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f }()
}
