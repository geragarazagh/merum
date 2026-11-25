// The one object that owns every note. The UI reads it and calls it; the store, the history and sync hang off it.
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class Library {
    enum Sort: String, CaseIterable { case manual, edited, created, title }

    /// What changed, in `Library.didChange`'s userInfo[Library.changeKey].
    enum Change {
        /// Notes came, went or changed places; read `notes` again (and `lastOpen`, which may have moved to a neighbour).
        case list
        /// One note's title.
        case title(Note)
        /// One note's text changed from outside the text view (another device): `range` is the new text's range in
        /// the note, `delta` the change in length. Undo and redo do not post this; they call `History.reveal`.
        case text(Note, range: NSRange, delta: Int)
        /// sort, ascending or textSize (here or from another device).
        case settings
    }
    nonisolated static let didChange = Notification.Name("MerumLibraryDidChange")
    nonisolated static let changeKey = "change"   // nosemgrep (the name of a notification userInfo key, not a secret)

    /// Text size steps in percent: Reader's own steps without 85 and 115, so every step is a visible change.
    nonisolated static let textSizes = [50, 75, 100, 125, 150, 175, 200, 250, 300]

    /// Pinned notes first, then the rest; each group in the current sort (in the manual order each group keeps its
    /// own order), as Apple Notes lists them.
    private(set) var notes: [Note] = []
    var sort: Sort = .manual { didSet { if sort != oldValue { settingsChanged() } } }
    /// Oldest (or A to Z) first. The manual order has no direction: it is the person's own.
    var ascending = true { didSet { if ascending != oldValue { settingsChanged() } } }
    /// Percent, one of `textSizes`.
    var textSize = 100 {
        didSet {
            if !Library.textSizes.contains(textSize) { textSize = Library.closestTextSize(textSize); return }
            if textSize != oldValue { settingsChanged() }
        }
    }
    /// When sort, ascending or textSize were last changed here (seconds since 1970; 0 never), for SettingsSync.
    var settingsModified: Double = 0 { didSet { store?.metaChanged() } }
    /// The note shown; per device, not synced. The UI sets it whenever it shows a note.
    var lastOpen: UUID? { didSet { if lastOpen != oldValue { store?.metaChanged() } } }

    let history: History
    let store: Store?
    /// Set by Sync.start; nil without iCloud.
    weak var sync: Sync?
    /// Set by SettingsSync.start.
    weak var settingsSync: SettingsSync?

    private var byID: [UUID: Note] = [:]
    /// Ids this library has held since it started (loaded, made, received).
    private var seen: Set<UUID> = []
    /// Notes the person made on this device (newNote, ensureNote, a draft adopted through restore) or emptied here (an
    /// edit here, undo included, that left the text empty), while the app runs: the only ones `leave` may drop. A note
    /// that came empty from iCloud and was not touched here is never dropped: another device may have it open and be
    /// about to type into it, or its text may not have arrived; dropping it would delete it on every device.
    private var madeHere: Set<UUID> = []
    private var observers: [UUID: NSObjectProtocol] = [:]
    /// While the core itself writes into a storage (undo, another device): such an edit is not the person typing.
    private(set) var applying: Applying?
    enum Applying { case undo, remote }

    /// `store` nil keeps everything in memory (tests).
    init(store: Store? = nil) {
        history = History()
        self.store = store
        history.library = self
        if let store {
            let loaded = store.load()
            sort = loaded.sort; ascending = loaded.ascending; textSize = loaded.textSize
            settingsModified = loaded.settingsModified
            for n in loaded.notes { attach(n) }
            lastOpen = loaded.lastOpen
            store.library = self
            if loaded.repaired { store.metaChanged() }
        }
        resort()
        if let id = lastOpen, byID[id] == nil { lastOpen = notes.first?.id }
        if lastOpen == nil { lastOpen = notes.first?.id }
    }

    func note(id: UUID) -> Note? { byID[id] }
    func contains(_ note: Note) -> Bool { byID[note.id] === note }

    // MARK: notes

    /// A new note with the lowest default name no note carries; last in the manual order. An undo step («New Note»).
    @discardableResult func newNote() -> Note {
        let n = Note(title: freeName(), position: (notes.map(\.position).max() ?? 0) + 1)
        n.storage.mutableString.setString("")
        madeHere.insert(n.id)
        attach(n)
        resort()
        store?.noteChanged(n.id)
        sync?.localCreated(n)
        history.registerCreated([n])
        post(.list)
        return n
    }

    /// The note input goes to: the one open, or, when there are none, a new one, so input never goes nowhere.
    func ensureNote() -> Note {
        if let id = lastOpen, let n = byID[id] { return n }
        let n = notes.first ?? newNote()
        lastOpen = n.id
        return n
    }

    /// Deletes for good; one undo step («Delete Note», «Delete Notes») brings them back.
    func delete(_ list: [Note]) {
        let gone = list.filter(contains)
        guard !gone.isEmpty else { return }
        remove(gone)
        sync?.localDeleted(gone)
        history.registerDeleted(gone)
    }

    /// A note left empty that was never renamed goes, silently and with no undo step of its own, the last one too (as
    /// Apple Notes drops an empty note: then there are simply no notes, and the first key makes one). Only a note made
    /// or emptied here (madeHere). Its text steps stay: undoing one brings the note back.
    func leave(_ note: Note) {
        guard contains(note), madeHere.contains(note.id), note.storage.length == 0, !note.renamed,
              !pastes.contains(where: { $0.note === note }) else { return }   // a paste is on its way into it
        remove([note])
        history.dropped(note)
        sync?.localDeleted([note])
    }

    /// An empty or blank name gives the note back a default name.
    func rename(_ note: Note, to name: String) {
        guard contains(note) else { return }
        let clean = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let old = (note.title, note.renamed)
        if clean.isEmpty {
            guard note.renamed else { return }
            note.renamed = false
            note.title = freeName(except: note)
        } else {
            guard clean != note.title || !note.renamed else { return }
            note.title = clean
            note.renamed = true
        }
        note.modified = Date()
        titleChanged(note)
        history.registerRenamed(note, from: old)
    }

    /// Moves notes in the manual order so that they stand, in their present order, before the note now at `index`
    /// of `notes` (notes.count: at the end), as a table's drop does. Only in the manual order, and only inside one
    /// group: the notes of the first moved note's group (pinned or not) move, an index outside that group stops at
    /// its edge. «Move Note».
    func move(_ list: [Note], toIndex index: Int) {
        guard sort == .manual, let first = notes.first(where: { n in list.contains { $0 === n } }) else { return }
        let group = notes.filter { $0.pinned == first.pinned }
        let start = notes.firstIndex { $0 === group[0] }!
        let moving = group.filter { n in list.contains { $0 === n } }
        let before = group.map { ($0, $0.position) }
        let index = max(0, min(index - start, group.count))
        let stay = group.enumerated().filter { e in !moving.contains { $0 === e.element } }
        let at = stay.firstIndex { $0.offset >= index } ?? stay.count
        let prev = at > 0 ? stay[at - 1].element.position : nil
        let next = at < stay.count ? stay[at].element.position : nil
        let lo = prev ?? (next.map { $0 - Double(moving.count + 1) } ?? 0)
        let hi = next ?? lo + Double(moving.count + 1)
        let stepSize = (hi - lo) / Double(moving.count + 1)
        if stepSize < 1e-6 * max(1, abs(lo)) {
            // The gap wore out after many moves: number the group again, the moved notes in their new place.
            var order = stay.map(\.element)
            order.insert(contentsOf: moving, at: at)
            for (i, n) in order.enumerated() { n.position = Double(i + 1) }
        } else {
            for (i, n) in moving.enumerated() { n.position = lo + stepSize * Double(i + 1) }
        }
        let changed = before.filter { $0.0.position != $0.1 }
        guard !changed.isEmpty else { return }
        resort()
        for (n, _) in changed { store?.noteMetaChanged(n.id); sync?.localFieldsChanged(n) }
        history.registerMoved(changed)
        post(.list)
    }

    // MARK: used by History (undo and redo of whole notes)

    /// Puts notes back as they were (same id, text, position). Not an undo step by itself.
    func restore(_ list: [Note]) {
        let back = list.filter { byID[$0.id] == nil }
        guard !back.isEmpty else { return }
        for n in back {
            if !seen.contains(n.id) { madeHere.insert(n.id) }   // a note never held before: made here (an adopted draft)
            attach(n); store?.noteRestored(n.id)
        }
        resort()
        sync?.localRestored(back)
        post(.list)
    }

    /// Removes without an undo step (the undo of «New Note», a redo of a delete).
    func removeQuietly(_ list: [Note]) {
        let gone = list.filter(contains)
        guard !gone.isEmpty else { return }
        remove(gone)
        sync?.localDeleted(gone)
    }

    func setTitle(_ note: Note, _ title: String, renamed: Bool) {
        note.title = title; note.renamed = renamed; note.modified = Date()
        titleChanged(note)
    }

    /// Pins or unpins; one undo step («Pin Note», «Pin Notes», «Unpin Note», «Unpin Notes», Apple Notes' words). The
    /// date edited stays, as in Apple Notes.
    func pin(_ list: [Note], _ on: Bool) {
        let changed = notes.filter { n in n.pinned != on && list.contains { $0 === n } }
        guard !changed.isEmpty else { return }
        setPinned(changed, on)
        history.registerPinned(changed, on)
    }

    func setPinned(_ list: [Note], _ on: Bool) {
        for n in list { n.pinned = on; store?.noteMetaChanged(n.id); sync?.localFieldsChanged(n) }
        resort()
        post(.list)
    }

    func setPositions(_ list: [(Note, Double)]) {
        for (n, p) in list { n.position = p; store?.noteMetaChanged(n.id); sync?.localFieldsChanged(n) }
        resort()
        post(.list)
    }

    /// Writes into a note's text for undo or redo; brings back a note that `leave` dropped.
    func applyUndo(_ note: Note, range: NSRange, with string: String) -> Bool {
        if !contains(note) {
            guard byID[note.id] == nil else { return false }
            restore([note])
        }
        guard NSMaxRange(range) <= note.storage.length else { return false }
        willEditText(note)
        applying = .undo
        note.storage.replaceCharacters(in: range, with: string)
        applying = nil
        return true
    }

    /// Called before any local edit of a note's text (the person typing, undo): sync keeps the text as last synced.
    func willEditText(_ note: Note) { sync?.localTextWillChange(note) }

    // MARK: used by Sync (changes from other devices)

    /// Replaces the text with `new` by the smallest replacement (common prefix and suffix kept), so an open note's
    /// caret and scroll stay; drops the note's text steps from the history. Returns whether anything changed.
    @discardableResult func applyRemote(_ note: Note, text new: NSString, modified: Date?) -> Bool {
        guard let r = Diff.minimalReplacement(from: note.storage.mutableString, to: new) else { return false }
        applying = .remote
        note.storage.replaceCharacters(in: r.range, with: r.string)
        applying = nil
        if let modified { note.modified = modified }
        history.dropText(of: note)
        store?.noteChanged(note.id)
        if sort == .edited { resortIfNeeded() }
        post(.text(note, range: NSRange(location: r.range.location, length: (r.string as NSString).length),
                   delta: (r.string as NSString).length - r.range.length))
        return true
    }

    /// A note made on another device.
    func insertRemote(_ note: Note) {
        guard byID[note.id] == nil else { return }
        attach(note)
        resort()
        store?.noteChanged(note.id)
        post(.list)
    }

    /// A note deleted on another device: gone here too, with its text steps; not an undo step.
    func removeRemote(_ note: Note) {
        guard contains(note) else { return }
        history.forget(note)
        remove([note])
    }

    /// Title, dates, position or renamed from another device.
    func updateRemote(_ note: Note, title: String?, renamed: Bool?, created: Date?, modified: Date?, position: Double?,
                      pinned: Bool? = nil) {
        var titleMoved = false, listMoved = false
        if let pinned, pinned != note.pinned { note.pinned = pinned; listMoved = true }
        if let title, title != note.title { note.title = title; titleMoved = true }
        if let renamed { note.renamed = renamed }
        if let created, created != note.created { note.created = created; listMoved = sort == .created }
        if let modified, modified != note.modified { note.modified = modified; listMoved = listMoved || sort == .edited }
        if let position, position != note.position { note.position = position; listMoved = listMoved || sort == .manual }
        store?.noteMetaChanged(note.id)
        if titleMoved { post(.title(note)); listMoved = listMoved || sort == .title }
        if listMoved { resort(); post(.list) }
    }

    /// Sort settings and text size from another device.
    func updateSettingsRemote(sort: Sort?, ascending: Bool?, textSize: Int?) {
        fromCloud = true
        if let sort { self.sort = sort }
        if let ascending { self.ascending = ascending }
        if let textSize { self.textSize = textSize }
        fromCloud = false
    }
    private var fromCloud = false

    // MARK: a paste that takes time (a picture read by Vision)

    /// Pastes waiting for their text.
    private(set) var pastes: [PendingPaste] = []

    /// A paste whose text comes later: its place follows the edits made meanwhile, and the note it goes into is not
    /// dropped as empty while it waits. `range`: the selection the paste replaces (empty: the caret).
    func beginPaste(in note: Note, replacing range: NSRange) -> PendingPaste {
        let p = PendingPaste(note: note, range: range)
        pastes.append(p)
        return p
    }

    /// Puts the text where the paste was made, as one undo step «Paste». It replaces the selection the paste was made
    /// over unless that text was edited meanwhile (then it goes in before it and nothing is removed). Returns the range
    /// of the pasted text, nil when there was none (a picture with no text) or the paste was cancelled. A note
    /// deleted meanwhile still gets the text, so undoing the delete brings both back.
    @discardableResult func finishPaste(_ p: PendingPaste, with text: String) -> NSRange? {
        guard let i = pastes.firstIndex(where: { $0 === p }) else { return nil }
        pastes.remove(at: i)
        let note = p.note
        guard !text.isEmpty else {
            if lastOpen != note.id { leave(note) }   // it was spared while it waited
            return nil
        }
        let r = NSRange(location: min(p.range.location, note.length),
                        length: min(p.range.length, max(0, note.length - p.range.location)))
        if contains(note) {
            history.willReplace(in: note, range: r, with: text, as: .paste)
        } else {
            history.dropText(of: note)   // its earlier steps would no longer fit the text
        }
        note.storage.replaceCharacters(in: r, with: text)
        return NSRange(location: r.location, length: (text as NSString).length)
    }

    func cancelPaste(_ p: PendingPaste) {
        pastes.removeAll { $0 === p }
        if p.note.length == 0, lastOpen != p.note.id { leave(p.note) }
    }

    /// Whatever the pasteboard held, into the note: text at once, a picture once Vision has read it (from a fraction
    /// of a second to over a minute the first time after a restart, while Vision prepares its model). The person can
    /// go on typing and switching notes meanwhile. Returns the range of the pasted text (nil: nothing to put in, beep).
    func paste(_ content: Paste.Content, into note: Note, replacing range: NSRange) async -> NSRange? {
        switch content {
        case .text(let s):
            let p = beginPaste(in: note, replacing: range)
            return finishPaste(p, with: s)
        case .image(let image):
            let p = beginPaste(in: note, replacing: range)
            let text = await Paste.recognize(image)
            return finishPaste(p, with: text)
        }
    }

    /// Writes everything pending now (hide, background, quit).
    func flush() { store?.flush() }

    // MARK: private

    private func attach(_ n: Note) {
        byID[n.id] = n
        seen.insert(n.id)
        notes.append(n)
        observers[n.id] = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: n.storage, queue: nil) { [weak self, weak n] _ in
            guard let n else { return }
            MainActor.assumeIsolated { self?.storageEdited(n) }
        }
    }

    private func remove(_ list: [Note]) {
        let ids = Set(list.map(\.id))
        var lastGone: Int?
        if let open = lastOpen, ids.contains(open) { lastGone = notes.firstIndex { $0.id == open } }
        for n in list {
            byID[n.id] = nil
            if let o = observers.removeValue(forKey: n.id) { NotificationCenter.default.removeObserver(o) }
            store?.noteRemoved(n.id)
        }
        // The note that takes the open one's place in the list is shown next, else the one above (Apple Notes).
        if let at = lastGone {
            let after = notes[(at + 1)...].first { !ids.contains($0.id) }
            let before = notes[..<at].last { !ids.contains($0.id) }
            lastOpen = (after ?? before)?.id
        }
        notes.removeAll { ids.contains($0.id) }
        post(.list)
    }

    private func storageEdited(_ n: Note) {
        guard n.storage.editedMask.contains(.editedCharacters) else { return }
        for p in pastes where p.note === n { p.shift(n.storage.editedRange, n.storage.changeInLength) }
        guard contains(n) else { return }
        store?.noteChanged(n.id)
        guard applying != .remote else { return }
        if n.storage.length == 0 { madeHere.insert(n.id) }   // emptied here: may go when left
        n.modified = Date()
        sync?.localTextChanged(n)
        if sort == .edited { resortIfNeeded() }
    }

    private func titleChanged(_ n: Note) {
        store?.noteMetaChanged(n.id)
        sync?.localFieldsChanged(n)
        post(.title(n))
        if sort == .title || sort == .edited { resortIfNeeded() }
    }

    private func settingsChanged() {
        store?.metaChanged()
        if !fromCloud { settingsSync?.localChanged() }
        resort()
        post(.settings)
        post(.list)
    }

    private func resortIfNeeded() {
        let before = notes.map(\.id)
        resort()
        if notes.map(\.id) != before { post(.list) }
    }

    private func resort() {
        let up = sort == .manual || ascending
        notes.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            switch sort {
            case .manual: if a.position != b.position { return a.position < b.position }
            case .edited: if a.modified != b.modified { return (a.modified < b.modified) == up }
            case .created: if a.created != b.created { return (a.created < b.created) == up }
            case .title:
                let c = a.title.localizedStandardCompare(b.title)
                if c != .orderedSame { return (c == .orderedAscending) == up }
            }
            if a.created != b.created { return a.created < b.created }
            return a.id.uuidString < b.id.uuidString
        }
    }

    func post(_ change: Change) {
        NotificationCenter.default.post(name: Library.didChange, object: self, userInfo: [Library.changeKey: change])
    }

    /// The lowest default name that no note carries (`except` itself does not count).
    func freeName(except: Note? = nil) -> String {
        let taken = Set(notes.filter { $0 !== except }.map(\.title))
        var i = 1
        while taken.contains(Ordinal.noteName(i)) { i += 1 }
        return Ordinal.noteName(i)
    }

    nonisolated static func closestTextSize(_ v: Int) -> Int { textSizes.min { abs($0 - v) < abs($1 - v) }! }
}
