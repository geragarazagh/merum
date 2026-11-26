// What the screens show, read from the Library and kept in step with it.
import SwiftUI
import UIKit

enum Route: Hashable { case editor }

struct Row: Identifiable, Hashable {
    let id: UUID
    let title: String
    let pinned: Bool
    let modified: Date
    /// The note's first text, folded to one line, as much as a row shows.
    let preview: String
}

@MainActor @Observable final class Model {
    @ObservationIgnored let library: Library
    @ObservationIgnored private(set) var editors: Editors!

    /// The notes in the current sort, names only.
    private(set) var rows: [Row] = []
    var path: [Route] = []
    /// The note in the editor. nil only while there are no notes at all: then `draft` is shown, a note not yet in
    /// the library that joins it with its first edit (input never goes nowhere, nothing appears by itself).
    private(set) var open: Note?
    private(set) var draft: Note?
    var current: Note? { open ?? draft }
    /// Bumped when a title changes, so the navigation title reads it again.
    private(set) var titleVersion = 0

    var selecting = false { didSet { if !selecting { selection = [] } } }
    var selection = Set<UUID>()
    private(set) var keyboardUp = false
    /// The list's bottom bar: off from launch until the list is first in front or a second has passed (ListScreen).
    var listBarShown = false
    /// Counts text fields and views ending their editing (the rename field, a note): the list's undo responder takes
    /// over then.
    private(set) var editingEnded = 0
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// The open note's characters, words and tokens (counted off the main thread; nil while counting).
    private(set) var facts: Facts? { didSet { editors?.showFacts(facts) } }
    @ObservationIgnored private var factsTask: Task<Void, Never>?
    /// The list's search: names and texts that contain it (case and diacritics ignored).
    var query = "" { didSet { if query != oldValue { search() } } }
    private(set) var found: Set<UUID>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private(set) var textSize: Int
    private(set) var sort: Library.Sort
    private(set) var ascending: Bool

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(library: Library) {
        self.library = library
        sort = library.sort
        ascending = library.ascending
        textSize = library.textSize
        editors = Editors(model: self)
        refreshRows()
        // Opens straight on the last note open, always.
        if let id = library.lastOpen, let n = library.note(id: id) { open = n } else { draft = makeDraft() }
        path = [.editor]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.listBarShown = true }
        editors.focusNext = true
        if let c = current {
            editors.openAtEnd(c)
            // Counted before the first frame, so the counter rises with the keyboard, never blank first.
            facts = c.length < 50_000 ? Facts(c.storage.string) : nil
            editors.showFacts(facts)   // observers do not run inside init
            count(after: 0)
        }
        library.history.reveal = { [weak self] note, range in self?.reveal(note, range) }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Library.didChange, object: library, queue: nil) { [weak self] n in
            let change = n.userInfo?[Library.changeKey] as? Library.Change
            MainActor.assumeIsolated { self?.changed(change) }
        })
        // Typing in a note, not the keyboard on screen: with the keyboard down the editor's bar is an input of its own
        // (EditorDock), which UIKit also reports as a keyboard.
        observers.append(nc.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: nil) { [weak self] n in
            let note = n.object is NoteTextView
            MainActor.assumeIsolated { if note { self?.keyboardUp = true } }
        })
        observers.append(nc.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: nil) { [weak self] n in
            let note = n.object is NoteTextView
            MainActor.assumeIsolated { if note { self?.keyboardUp = false } }
        })
        // Posted inside the keyboard's animation, so the text's room changes along with it.
        observers.append(nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil) { [weak self] n in
            let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            let curve = (n.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
            MainActor.assumeIsolated { if let end { self?.editors.keyboard(frame: end, duration: duration, curve: curve) } }
        })
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.editingEnded += 1 }
            })
        }
        let um = library.history.undoManager
        // Not NSUndoManagerCheckpoint: reading canUndo or canRedo posts it, so listening to it looped for ever (a
        // spinning main thread, found by the stress pass 2026-11-25).
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange] {
            observers.append(nc.addObserver(forName: name, object: um, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.undoChanged() }
            })
        }
        observers.append(nc.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: nil) { [weak self] n in
            let st = n.object as? NSTextStorage
            MainActor.assumeIsolated {
                if let self, st != nil, st === self.current?.storage { self.count(after: 0.3); self.freshenOpenRow() }
            }
        })
        observers.append(nc.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.editors.applyTextSize() }
        })
    }

    @ObservationIgnored private var undoReadPending = false
    private func undoChanged() {
        let um = library.history.undoManager
        // The manager posts mid-step too; read it once the step has settled, at most once a turn of the run loop.
        guard !undoReadPending else { return }
        undoReadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.undoReadPending = false
            if self.canUndo != um.canUndo { self.canUndo = um.canUndo }
            if self.canRedo != um.canRedo { self.canRedo = um.canRedo }
        }
    }

    func undo() { editors.undo() }
    func redo() { editors.redo() }

    /// Counts the open note again after a pause in typing.
    func count(after delay: Double) {
        factsTask?.cancel()
        guard let n = current else { facts = nil; return }
        // Waits for a pause in typing before it copies the text (~1 ms per 10 M characters) and counts it off the
        // main thread, so a keystroke costs only this restart.
        factsTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            guard let f = await Facts.of(n.textSnapshot), !Task.isCancelled, let self, self.current === n else { return }
            self.facts = f
        }
    }

    private func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { found = nil; return }
        let items = library.notes.map { ($0.id, $0.title, $0.textSnapshot) }
        searchTask = Task { [weak self] in
            let hits = await Task.detached(priority: .userInitiated) { () -> Set<UUID> in
                var out = Set<UUID>()
                for (id, title, text) in items {
                    if Task.isCancelled { break }
                    let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
                    if title.range(of: q, options: opts) != nil || text.range(of: q, options: opts).location != NSNotFound {
                        out.insert(id)
                    }
                }
                return out
            }.value
            guard !Task.isCancelled, let self else { return }
            self.found = hits
        }
    }

    var shownRows: [Row] { found.map { f in rows.filter { f.contains($0.id) } } ?? rows }

    /// Delete from the editor's menu: the note goes, the list comes back (Notes on iPhone).
    func deleteOpen() {
        guard let n = current else { return }
        path = []
        if library.contains(n) { library.delete([n]) } else { draft = makeDraft() }
    }

    private func makeDraft() -> Note {
        Note(title: library.freeName(), position: (library.notes.map(\.position).max() ?? 0) + 1)
    }

    // MARK: the editor

    /// Shows a note in the editor; the note left behind goes if it is empty and was never named (Library.leave).
    func show(_ note: Note) {
        if let o = open, o !== note {
            // An undo or redo that brings another note forward must not drop the note left behind mid-step: dropping
            // it removes its undo steps while the manager is undoing (the stress pass hung in History's undo loop).
            let um = library.history.undoManager
            if um.isUndoing || um.isRedoing {
                DispatchQueue.main.async { [weak self] in self?.library.leave(o) }
            } else {
                library.leave(o)
            }
        }
        editors.focusNext = true
        open = note
        editors.openAtEnd(note)
        draft = nil
        library.lastOpen = note.id
        if path.isEmpty { path = [.editor] }
        // A note of ordinary size is counted at once, so its line shows with the note, never blank first.
        facts = note.length < 50_000 ? Facts(note.storage.string) : nil
        count(after: 0)
    }

    /// Back from the editor to the list.
    func leftEditor() {
        refreshRows()   // the edited note's time and first text
        editors.leave()
        // An empty note goes once the list is on screen, so its row is seen leaving, as in Notes; not if the person
        // came straight back to it.
        guard let o = open else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.path.isEmpty || self.open !== o else { return }
            withAnimation { self.library.leave(o) }
        }
    }

    /// A new note, shown with the keyboard up (as Notes does for a new note).
    func compose() {
        selecting = false
        let n = library.newNote()
        show(n)
    }

    /// The draft becomes a note with its first edit (or a rename). Not an undo step: undoing the edit leaves an
    /// empty note, which goes when left.
    func adopt(_ note: Note) {
        guard draft === note, !library.contains(note) else { return }
        draft = nil
        open = note
        library.restore([note])
        library.lastOpen = note.id
    }

    func rename(to name: String) {
        guard let n = current else { return }
        adopt(n)
        library.rename(n, to: name)
    }

    func endEditing() { editors.endEditing() }

    /// After an undo or redo: the note it touched is shown (from the list too, for a text step) and its range selected.
    private func reveal(_ note: Note, _ range: NSRange?) {
        guard library.contains(note) else { return }
        if path.isEmpty {
            // On the list a whole note coming back is seen as its row; only a text change opens the note.
            guard range != nil else { return }
            show(note)
        } else if open !== note {
            show(note)
        }
        if let range { editors.select(range, in: note) }
    }

    // MARK: the list

    func open(_ id: UUID) {
        guard let n = library.note(id: id) else { return }
        show(n)
    }

    func notes(_ ids: Set<UUID>) -> [Note] { library.notes.filter { ids.contains($0.id) } }

    func delete(_ ids: Set<UUID>) {
        library.delete(notes(ids))
        selection.subtract(ids)
    }

    /// The notes' texts as plain text, in the list's order, one line break between them (as the Mac app and Copia).
    func copy(_ ids: Set<UUID>) {
        let texts = notes(ids).map { $0.storage.string }
        guard !texts.isEmpty else { return }
        UIPasteboard.general.string = texts.joined(separator: "\n")
    }

    /// A drop inside one section (offsets in that section's own rows), as the list reports it.
    func move(pinned: Bool, from offsets: IndexSet, to index: Int) {
        let start = pinned ? 0 : library.notes.filter(\.pinned).count
        let list = offsets.map { library.notes[start + $0] }
        library.move(list, toIndex: start + index)
    }

    /// Pins the notes unless all of them are pinned already, then unpins them (one step, the core's words).
    func togglePin(_ ids: Set<UUID>) {
        let list = notes(ids)
        guard !list.isEmpty else { return }
        library.pin(list, !list.allSatisfy(\.pinned))
    }
    func allPinned(_ ids: Set<UUID>) -> Bool { let l = notes(ids); return !l.isEmpty && l.allSatisfy(\.pinned) }

    func setSort(_ s: Library.Sort) { library.sort = s }
    func setAscending(_ a: Bool) { library.ascending = a }

    func selectAll() { selection = Set(rows.map(\.id)) }

    // MARK: changes from the library

    /// The first 160 characters with line breaks and runs of spaces folded, enough for a row's width on any iPhone.
    static func preview(_ n: Note) -> String {
        let head = n.storage.mutableString.substring(to: min(n.length, 160))
        return head.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func refreshRows() {
        rows = library.notes.map(Model.row)
    }

    private static func row(_ n: Note) -> Row {
        Row(id: n.id, title: n.title, pinned: n.pinned, modified: n.modified, preview: preview(n))
    }

    /// The open note's row follows its text while it is typed in, so the list behind the editor is already right when
    /// it comes back (a back swipe shows it from the gesture's first frame). Until 0.2 the row was read again only
    /// once the list was back, and the list's animation crossfaded the old «No additional text» into the new text
    /// for ~0.2 s. Once a turn of the run loop at most (a paste of a book is one change, typing one per key), and only
    /// when what the row shows changes: the first 160 characters or the minute of its time.
    @ObservationIgnored private var rowPending = false
    private func freshenOpenRow() {
        guard !rowPending else { return }
        rowPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rowPending = false
            guard let n = self.open, let i = self.rows.firstIndex(where: { $0.id == n.id }) else { return }
            let old = self.rows[i], new = Model.row(n)
            guard new.preview != old.preview || NoteDate.text(new.modified) != NoteDate.text(old.modified) else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.rows[i] = new }
        }
    }

    private func changed(_ change: Library.Change?) {
        switch change {
        case .title:
            titleVersion += 1
            refreshRows()
        case .settings:
            sort = library.sort
            ascending = library.ascending
            textSize = library.textSize
            editors.applyTextSize()
        case .text, nil:
            break
        case .list:
            refreshRows()
            selection = selection.intersection(rows.map(\.id))
            if found != nil { search() }
            if let o = open, !library.contains(o) {
                // The open note went (undo of New Note, deleted on another device): its neighbour takes its place, as
                // in Notes; with none left the editor shows a fresh draft.
                if let id = library.lastOpen, let n = library.note(id: id) { open = n } else { open = nil; draft = makeDraft() }
            }
            if let d = draft, d.storage.length == 0, let first = library.notes.first {
                // A note arrived (another device, an undo) while the draft was untouched: it is shown instead.
                draft = nil
                open = first
                library.lastOpen = first.id
            }
            titleVersion += 1
            editors.dropViews(keeping: Set(library.notes.map(\.id)))
        }
    }
}
