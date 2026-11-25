// One undo history for the whole app, in the order things were done: typing in one note, then in another, deleting a
// note, renaming one, all on one stack, as a person remembers it. The text views keep no undo of their own.
//
// Text steps are coalesced the way NSTextView's typing undo is: a step holds where its text starts, how long the
// inserted text is now and what it replaced; typing at the caret, Delete and Forward Delete next to it and an input
// method's marked text (always replaced at the caret's end) only reshape the open step, so one ⌘Z takes back a whole
// run of typing and never a half-composed character. The run ends when the caret moves (`breakTyping`), another note
// or another kind of edit comes, or an undo or a whole-note step happens.
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class History {
    /// What an edit is, for coalescing and for the menu («Undo Typing»). Apple's words.
    enum Kind: Equatable {
        case typing, paste, cut, delete
        case named(String)
        var name: String {
            switch self {
            case .typing: "Typing"
            case .paste: "Paste"
            case .cut: "Cut"
            case .delete: "Delete"
            case .named(let s): s
            }
        }
    }

    /// The UndoManager the window (Mac) or the text view (iPhone) hands out, so Edit > Undo, ⌘Z, ⇧⌘Z and shake reach
    /// it.
    let undoManager: UndoManager
    /// Called after an undo or redo changed a note's text, with the range to select (the restored text; empty: the
    /// caret). The UI shows that note first if another one is open, then selects and scrolls to the range. Also called
    /// with nil after one note came back (undo of a delete), to show it.
    var reveal: ((Note, NSRange?) -> Void)?

    weak var library: Library?

    private final class Manager: UndoManager {
        weak var history: History?
        // An undo group can find nothing to do: the note it would remove is already gone (dropped when left empty,
        // deleted on another device). Such a step is passed over, so one ⌘Z always changes something.
        override func undo() {
            MainActor.assumeIsolated {
                history?.open = nil
                repeat { history?.acted = false; history?.wholeNoteNamed = false; super.undo() } while history?.acted == false && canUndo
            }
        }
        override func redo() {
            MainActor.assumeIsolated {
                history?.open = nil
                repeat { history?.acted = false; history?.wholeNoteNamed = false; super.redo() } while history?.acted == false && canRedo
            }
        }
    }

    /// One registration target per note for its text steps: a change from another device drops that note's text
    /// steps only. Another per note for the steps about the note itself (created, renamed, moved alone): dropped when
    /// the note goes without an undo step (left empty, deleted on another device), so no step that would do nothing
    /// is left on the stack for the Edit menu to name.
    private final class TextTarget {}
    private final class NoteTarget {}
    private var targets: [UUID: TextTarget] = [:]
    private var noteTargets: [UUID: NoteTarget] = [:]

    /// Whether the undo group being filled already carries a whole-note step. Such a group is named after that step:
    /// its text steps can be dropped later (another device), its whole-note step cannot, so the menu stays true. A new
    /// note and its first key in one event («New Note» + «Typing») read «Undo New Note», which is also what ⌘Z does.
    fileprivate var wholeNoteNamed = false
    private var groupObserver: NSObjectProtocol?

    private func name(_ s: String, wholeNote: Bool) {
        if wholeNote { wholeNoteNamed = true; undoManager.setActionName(s) }
        else if !wholeNoteNamed { undoManager.setActionName(s) }
    }

    private final class Step {
        let note: Note
        var location: Int
        var inserted: Int
        var deleted: String
        let kind: Kind
        init(_ note: Note, _ location: Int, _ inserted: Int, _ deleted: String, _ kind: Kind) {
            self.note = note; self.location = location; self.inserted = inserted; self.deleted = deleted; self.kind = kind
        }
        var end: Int { location + inserted }
    }
    private var open: Step?
    fileprivate var acted = false

    init() {
        let m = Manager()
        // Apple's apps keep a long history; this one lives only while the app runs, so no limit.
        m.levelsOfUndo = 0
        undoManager = m
        m.history = self
        groupObserver = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidOpenUndoGroup, object: m, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { if m.groupingLevel == 1 { self?.wholeNoteNamed = false } }
        }
    }

    // MARK: text

    /// The UI calls this before every change it makes to a note's text (typing, marked text, paste, cut, drop),
    /// with the range about to be replaced and the new string.
    func willReplace(in note: Note, range: NSRange, with string: String, as kind: Kind = .typing) {
        let new = (string as NSString).length
        guard range.length > 0 || new > 0, NSMaxRange(range) <= note.storage.length else { return }
        library?.willEditText(note)
        let text = note.storage.mutableString
        if kind == .typing, let s = open, s.note === note {
            if NSMaxRange(range) == s.end {
                // Ends at the caret: typing, Delete, marked text replaced.
                if range.location >= s.location {
                    s.inserted = range.location - s.location + new
                } else {
                    s.deleted = text.substring(with: NSRange(location: range.location, length: s.location - range.location)) + s.deleted
                    s.location = range.location
                    s.inserted = new
                }
                return
            }
            if range.location == s.end {
                // Starts at the caret: Forward Delete.
                s.deleted += text.substring(with: range)
                s.inserted += new
                return
            }
        }
        let step = Step(note, range.location, new, text.substring(with: range), kind)
        open = kind == .typing ? step : nil
        register(step)
    }

    /// The caret or selection moved by the person (a click, an arrow key): the typing run ends. Not while marked text
    /// is being composed, and not for the selection change an edit makes by itself.
    func breakTyping() { open = nil }

    /// A change from another device in this note: its text steps no longer fit the text and go; whole-note steps stay.
    func dropText(of note: Note) {
        if open?.note === note { open = nil }
        if let t = targets[note.id] { undoManager.removeAllActions(withTarget: t) }
    }

    /// The note went without an undo step (Library.leave): its own steps (created, renamed) would do nothing and go.
    /// Its text steps stay: undoing one brings the note back.
    func dropped(_ note: Note) {
        if let t = noteTargets[note.id] { undoManager.removeAllActions(withTarget: t) }
    }

    /// The note was deleted on another device: every step of its own goes.
    func forget(_ note: Note) {
        dropText(of: note)
        dropped(note)
    }

    private func noteTarget(_ note: Note) -> NoteTarget {
        if let t = noteTargets[note.id] { return t }
        let t = NoteTarget()
        noteTargets[note.id] = t
        return t
    }

    /// Steps about one note register on that note's target, steps about several on the history itself.
    private func registerWhole(_ notes: [Note], _ name: String, _ handler: @escaping (History) -> Void) {
        if notes.count == 1 {
            undoManager.registerUndo(withTarget: noteTarget(notes[0])) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            }
        } else {
            undoManager.registerUndo(withTarget: self) { h in MainActor.assumeIsolated { handler(h) } }
        }
        self.name(name, wholeNote: true)
    }

    private func target(_ note: Note) -> TextTarget {
        if let t = targets[note.id] { return t }
        let t = TextTarget()
        targets[note.id] = t
        return t
    }

    private func register(_ step: Step) {
        undoManager.registerUndo(withTarget: target(step.note)) { [weak self] _ in
            MainActor.assumeIsolated { self?.reverse(step) }
        }
        name(step.kind.name, wholeNote: false)
    }

    /// Undo (or redo) of a text step: puts back what it replaced and registers the opposite step.
    private func reverse(_ step: Step) {
        guard let library else { return }
        // A composition cancelled with Esc leaves a step that changed nothing: passed over.
        guard step.inserted > 0 || !step.deleted.isEmpty else { return }
        let note = step.note
        let range = NSRange(location: step.location, length: step.inserted)
        // A note dropped by `leave` keeps its storage, so its steps still fit; applyUndo brings it back.
        guard NSMaxRange(range) <= note.storage.length else { return }
        let now = note.storage.mutableString.substring(with: range)
        guard library.applyUndo(note, range: range, with: step.deleted) else { return }
        acted = true
        let back = Step(note, step.location, (step.deleted as NSString).length, now, step.kind)
        register(back)
        reveal?(note, NSRange(location: back.location, length: back.inserted))
    }

    // MARK: whole notes

    func registerCreated(_ notes: [Note]) {
        open = nil
        registerWhole(notes, "New Note") { $0.undoCreate(notes) }
    }

    private func undoCreate(_ notes: [Note]) {
        guard let library else { return }
        let present = notes.filter(library.contains)
        guard !present.isEmpty else { return }
        acted = true
        library.removeQuietly(present)
        registerWhole(present, "New Note") { $0.redoCreate(present) }
    }

    private func redoCreate(_ notes: [Note]) {
        guard let library else { return }
        library.restore(notes)
        acted = true
        registerCreated(notes)
        if notes.count == 1 { reveal?(notes[0], nil) }
    }

    func registerDeleted(_ notes: [Note]) {
        open = nil
        // On the history itself: a deleted note's own steps may be dropped meanwhile, its way back may not.
        undoManager.registerUndo(withTarget: self) { h in
            MainActor.assumeIsolated { h.undoDelete(notes) }
        }
        name(notes.count == 1 ? "Delete Note" : "Delete Notes", wholeNote: true)
    }

    private func undoDelete(_ notes: [Note]) {
        guard let library else { return }
        let back = notes.filter { library.note(id: $0.id) == nil }
        guard !back.isEmpty else { return }
        library.restore(back)
        acted = true
        undoManager.registerUndo(withTarget: self) { h in
            MainActor.assumeIsolated { h.redoDelete(back) }
        }
        name(back.count == 1 ? "Delete Note" : "Delete Notes", wholeNote: true)
        if back.count == 1 { reveal?(back[0], nil) }
    }

    private func redoDelete(_ notes: [Note]) {
        guard let library else { return }
        let present = notes.filter(library.contains)
        guard !present.isEmpty else { return }
        acted = true
        library.removeQuietly(present)
        registerDeleted(present)
    }

    func registerRenamed(_ note: Note, from old: (String, Bool)) {
        open = nil
        registerWhole([note], "Rename Note") { $0.undoRename(note, to: old) }
    }

    private func undoRename(_ note: Note, to old: (String, Bool)) {
        guard let library, library.contains(note) else { return }
        let now = (note.title, note.renamed)
        guard now != old else { return }
        acted = true
        library.setTitle(note, old.0, renamed: old.1)
        registerRenamed(note, from: now)
        reveal?(note, nil)
    }

    func registerPinned(_ notes: [Note], _ on: Bool) {
        open = nil
        registerWhole(notes, History.pinName(on, notes.count)) { $0.undoPin(notes, on) }
    }

    static func pinName(_ on: Bool, _ count: Int) -> String { (on ? "Pin " : "Unpin ") + (count == 1 ? "Note" : "Notes") }

    private func undoPin(_ notes: [Note], _ on: Bool) {
        guard let library else { return }
        let present = notes.filter { library.contains($0) && $0.pinned == on }
        guard !present.isEmpty else { return }
        acted = true
        library.setPinned(present, !on)
        registerWhole(present, History.pinName(on, present.count)) { $0.redoPin(present, on) }
    }

    private func redoPin(_ notes: [Note], _ on: Bool) {
        guard let library else { return }
        let present = notes.filter { library.contains($0) && $0.pinned != on }
        guard !present.isEmpty else { return }
        acted = true
        library.setPinned(present, on)
        registerPinned(present, on)
    }

    func registerMoved(_ before: [(Note, Double)]) {
        open = nil
        registerWhole(before.map(\.0), "Move Note") { $0.undoMove(before) }
    }

    private func undoMove(_ before: [(Note, Double)]) {
        guard let library else { return }
        let present = before.filter { library.contains($0.0) && $0.0.position != $0.1 }
        guard !present.isEmpty else { return }
        acted = true
        let now = present.map { ($0.0, $0.0.position) }
        library.setPositions(present)
        registerMoved(now)
    }
}
