// Tests of the shared core, run on the Mac with no window and no iCloud: `./test` (all), `./test bench` (the
// timings and memory on bench/war-and-peace.txt and bench/ten-million.txt).
// Each group prints one line; a failure prints its line number and what differed, and the run exits 1.
import AppKit
import CloudKit
import Darwin
import Network

// MARK: harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String = "", line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("  FAIL line \(line): \(what())") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ what: String = "", line: Int = #line) {
    check(a == b, "\(what) got «\(a)» want «\(b)»", line: line)
}

func group(_ name: String, _ body: () throws -> Void) rethrows {
    let before = failures
    try body()
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

@MainActor func agroup(_ name: String, _ body: () async throws -> Void) async rethrows {
    let before = failures
    try await body()
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

/// One run-loop pass: the UndoManager closes the group it opened for this «event», as after a key press. (Inside the
/// async sync tests a nested pass does not reach UndoManager's observer, so their groups stay open: those tests check
/// texts, not undo groups; the history's own tests run outside async code.)
func endEvent() { RunLoop.main.run(mode: .default, before: Date()) }

func ms(_ start: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(start) * 1000) }

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

let benchDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("bench")

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("merum-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

extension Note { var text: String { storage.string } }

/// What a text view does for one edit: report it, then make it.
@MainActor func edit(_ lib: Library, _ n: Note, _ range: NSRange, _ s: String, _ kind: History.Kind = .typing) {
    lib.history.willReplace(in: n, range: range, with: s, as: kind)
    n.storage.replaceCharacters(in: range, with: s)
}

/// Types a string one character at a time at the end, each key its own event.
@MainActor func typeAtEnd(_ lib: Library, _ n: Note, _ s: String) {
    for c in s { edit(lib, n, NSRange(location: n.length, length: 0), String(c)); endEvent() }
}

@MainActor func backspace(_ lib: Library, _ n: Note, at caret: Int) {
    let r = (n.storage.string as NSString).rangeOfComposedCharacterSequence(at: caret - 1)
    edit(lib, n, r, ""); endEvent()
}

// MARK: Ordinal

func testOrdinal() {
    group("Ordinal.words 1...200, big numbers") {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        // The cardinal words against Foundation's own spell-out (which writes «one hundred twenty-one»).
        for n in Array(1...2000) + [10_000, 99_999, 100_001, 1_000_000, 1_234_567, 999_999_999, 1_000_000_001] {
            eq(Ordinal.cardinal(n).lowercased(), f.string(from: NSNumber(value: n))!, "cardinal \(n)")
        }
        let known: [Int: String] = [1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth", 8: "Eighth", 9: "Ninth",
            10: "Tenth", 11: "Eleventh", 12: "Twelfth", 13: "Thirteenth", 19: "Nineteenth", 20: "Twentieth",
            21: "Twenty-First", 22: "Twenty-Second", 23: "Twenty-Third", 30: "Thirtieth", 40: "Fortieth", 42: "Forty-Second",
            55: "Fifty-Fifth", 80: "Eightieth", 88: "Eighty-Eighth", 90: "Ninetieth", 98: "Ninety-Eighth", 99: "Ninety-Ninth",
            100: "One Hundredth", 101: "One Hundred First", 102: "One Hundred Second", 110: "One Hundred Tenth",
            111: "One Hundred Eleventh", 112: "One Hundred Twelfth", 120: "One Hundred Twentieth",
            121: "One Hundred Twenty-First", 199: "One Hundred Ninety-Ninth", 200: "Two Hundredth",
            1000: "One Thousandth", 1001: "One Thousand First", 2021: "Two Thousand Twenty-First",
            1_000_000: "One Millionth", 1_000_000_000: "One Billionth",
            1_234_567: "One Million Two Hundred Thirty-Four Thousand Five Hundred Sixty-Seventh",
            Int.max: "Nine Quintillion Two Hundred Twenty-Three Quadrillion Three Hundred Seventy-Two Trillion Thirty-Six Billion Eight Hundred Fifty-Four Million Seven Hundred Seventy-Five Thousand Eight Hundred Seventh"]
        for (n, w) in known { eq(Ordinal.words(n), w, "words \(n)") }
        var seen = Set<String>()
        for n in 1...200 {
            let w = Ordinal.words(n)
            check(seen.insert(w).inserted, "duplicate \(w)")
            check(!w.contains(" And ") && !w.contains("  "), w)
            // Every part capitalised, a hyphen only between tens and ones.
            for part in w.split(whereSeparator: { $0 == " " || $0 == "-" }) { check(part.first!.isUppercase, w) }
            if w.contains("-") { check(n % 100 > 20 && n % 10 != 0, "hyphen in \(w)") } else { check(n % 100 <= 20 || n % 10 == 0, "no hyphen in \(w)") }
        }
        eq(Ordinal.noteName(98), "Ninety-Eighth Note")
    }
}

// MARK: Library

@MainActor func testLibrary() {
    group("Library: names, sort, move, leave, ensureNote, rename") {
        let lib = Library()
        eq(lib.notes.count, 0)
        let a = lib.ensureNote()
        eq(a.title, "First Note"); eq(lib.lastOpen, a.id)
        let b = lib.newNote(), c = lib.newNote()
        eq([b.title, c.title], ["Second Note", "Third Note"])
        eq(lib.notes.map(\.title), ["First Note", "Second Note", "Third Note"], "manual order, new last")
        lib.delete([b])
        eq(lib.newNote().title, "Second Note", "the lowest free name")
        lib.rename(a, to: "  Fourth Note \n")
        eq(a.title, "Fourth Note"); check(a.renamed)
        eq(lib.newNote().title, "First Note", "a renamed note frees its default name and takes another")
        lib.rename(a, to: "   ")
        check(!a.renamed); check(lib.notes.filter { $0.title == a.title }.count == 1, "default name again, unique")
        // Move: drop row semantics.
        let l2 = Library()
        let n = (1...5).map { _ in l2.newNote() }
        l2.move([n[4]], toIndex: 0)
        eq(l2.notes.map(\.title), ["Fifth Note", "First Note", "Second Note", "Third Note", "Fourth Note"])
        l2.move([n[0], n[1]], toIndex: 5)
        eq(l2.notes.map(\.title), ["Fifth Note", "Third Note", "Fourth Note", "First Note", "Second Note"])
        l2.move([n[2]], toIndex: 2)   // before Fourth, where it already is: nothing changes
        eq(l2.notes.map(\.title), ["Fifth Note", "Third Note", "Fourth Note", "First Note", "Second Note"])
        // A thousand moves into the same gap wear out the doubles: numbering again keeps the order right.
        for _ in 0..<1000 { l2.move([l2.notes[4]], toIndex: 1) }
        eq(Set(l2.notes.map(\.title)).count, 5)
        check(zip(l2.notes, l2.notes.dropFirst()).allSatisfy { $0.position < $1.position }, "positions strictly rising")
        // Sorts.
        let l3 = Library()
        let x = l3.newNote(); let y = l3.newNote(); let z = l3.newNote()
        x.created = Date(timeIntervalSince1970: 300); y.created = Date(timeIntervalSince1970: 100); z.created = Date(timeIntervalSince1970: 200)
        l3.rename(x, to: "banana"); l3.rename(y, to: "Apple"); l3.rename(z, to: "cherry 10")
        l3.sort = .title
        eq(l3.notes.map(\.title), ["Apple", "banana", "cherry 10"])
        l3.ascending = false
        eq(l3.notes.map(\.title), ["cherry 10", "banana", "Apple"])
        l3.sort = .created
        eq(l3.notes.map(\.title), ["banana", "cherry 10", "Apple"], "newest first")
        l3.sort = .edited; l3.ascending = false
        var posted: [Library.Change] = []
        let o = NotificationCenter.default.addObserver(forName: Library.didChange, object: l3, queue: nil) { posted.append($0.userInfo![Library.changeKey] as! Library.Change) }
        edit(l3, y, NSRange(location: 0, length: 0), "x")
        eq(l3.notes.first?.id, y.id, "edited note goes to the top")
        check(posted.contains { if case .list = $0 { return true }; return false }, "list change posted")
        NotificationCenter.default.removeObserver(o)
        l3.move([x], toIndex: 0)   // not manual: ignored
        eq(l3.notes.first?.id, y.id)
        // leave
        let l4 = Library()
        let p = l4.newNote(), q = l4.newNote()
        l4.leave(p)
        eq(l4.notes.count, 1, "empty unrenamed note left: dropped"); check(!l4.contains(p))
        l4.lastOpen = q.id
        l4.leave(q)
        eq(l4.notes.count, 0, "the last note too: then there are no notes"); eq(l4.lastOpen, nil)
        let q2 = l4.ensureNote(); eq(q2.title, "First Note", "the first key makes one")
        let r = l4.newNote(); l4.rename(r, to: "Named")
        l4.leave(r); check(l4.contains(r), "renamed stays")
        edit(l4, q2, NSRange(location: 0, length: 0), " ")
        l4.leave(q2); check(l4.contains(q2), "not empty stays")
        // A note from elsewhere (disk, iCloud): stays when left empty untouched; goes once emptied here.
        let old = Note(title: "Old", position: 9, storage: NSTextStorage(string: ""))
        l4.insertRemote(old)
        l4.leave(old); check(l4.contains(old), "arrived empty, not touched here: stays")
        let older = Note(title: "Older", position: 10, storage: NSTextStorage(string: "written earlier"))
        l4.insertRemote(older)
        edit(l4, older, NSRange(location: 0, length: older.length), "", .cut)
        l4.leave(older); check(!l4.contains(older), "emptied here, then left: goes")
        // lastOpen moves to the neighbour on delete
        let l5 = Library()
        let s = (1...3).map { _ in l5.newNote() }
        l5.lastOpen = s[1].id
        l5.delete([s[1]]); eq(l5.lastOpen, s[2].id, "next note below")
        l5.delete([s[2]]); eq(l5.lastOpen, s[0].id, "then the one above")
        l5.delete([s[0]]); eq(l5.lastOpen, nil)
        let t = l5.ensureNote(); eq(t.title, "First Note"); eq(l5.lastOpen, t.id)
        // text size snaps
        l5.textSize = 110; eq(l5.textSize, 100); l5.textSize = 260; eq(l5.textSize, 250)
    }
}

@MainActor func testPinned() {
    group("Pinned: two groups, each in the sort; moves stay in their group; undo; store") {
        let lib = Library(); let um = lib.history.undoManager
        let n = (1...5).map { i -> Note in let x = lib.newNote(); x.created = Date(timeIntervalSince1970: Double(i) * 100); x.modified = x.created; return x }
        endEvent()
        lib.pin([n[3], n[1]], true); endEvent()
        eq(um.undoActionName, "Pin Notes")
        eq(lib.notes.map(\.title), ["Second Note", "Fourth Note", "First Note", "Third Note", "Fifth Note"], "pinned first, each group in manual order")
        lib.sort = .edited; lib.ascending = false
        eq(lib.notes.map(\.title), ["Fourth Note", "Second Note", "Fifth Note", "Third Note", "First Note"], "newest first inside each group")
        edit(lib, n[0], NSRange(location: 0, length: 0), "x"); endEvent()
        eq(lib.notes.map(\.title), ["Fourth Note", "Second Note", "First Note", "Fifth Note", "Third Note"], "an edited unpinned note tops its group, not the list")
        lib.sort = .manual
        lib.move([n[4]], toIndex: 0)   // an unpinned note dropped among the pinned: stops at the top of its group
        eq(lib.notes.map(\.title), ["Second Note", "Fourth Note", "Fifth Note", "First Note", "Third Note"])
        lib.move([n[1]], toIndex: 5)   // a pinned note dropped at the end: stops at the end of the pinned
        eq(lib.notes.map(\.title), ["Fourth Note", "Second Note", "Fifth Note", "First Note", "Third Note"])
        um.undo(); um.undo()
        eq(lib.notes.map(\.title), ["Second Note", "Fourth Note", "First Note", "Third Note", "Fifth Note"])
        lib.pin([n[1]], false); endEvent()
        eq(um.undoActionName, "Unpin Note")
        eq(lib.notes.first?.title, "Fourth Note")
        um.undo(); check(n[1].pinned); eq(um.redoActionName, "Unpin Note")
        um.redo(); check(!n[1].pinned)
        lib.pin([n[3]], true); check(!um.canRedo || um.redoActionName != "Unpin Note", "already pinned: no step")
        let before = n[2].modified
        lib.pin([n[2]], true); eq(n[2].modified, before, "pinning keeps the date edited")
        // notes.json keeps it.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        do { let l = Library(store: Store(dir: dir)); let a = l.newNote(); _ = l.newNote(); l.pin([a], true); l.flush() }
        let l2 = Library(store: Store(dir: dir))
        eq(l2.notes.map(\.pinned), [true, false])
        // A record from before pinning (no field) reads as unpinned; the field round-trips.
        let rec = CKRecord(recordType: "Note", recordID: CKRecord.ID(recordName: UUID().uuidString))
        rec["title"] = "Old" as NSString; rec["text"] = "t" as NSString
        eq(CloudKitDatabase.note(rec)?.pinned, false)
        rec["pinned"] = 1 as NSNumber
        eq(CloudKitDatabase.note(rec)?.pinned, true)
    }
}

@MainActor func testSettings() {
    group("Settings: sort syncs, text size is each device's own") {
        let mac = Library(), phone = Library()
        let ms = SettingsSync(library: mac), ps = SettingsSync(library: phone)
        mac.settingsSync = ms; phone.settingsSync = ps
        mac.textSize = 200
        eq(mac.settingsModified, 0, "a text size change is not a synced setting")
        check(ms.record()["textSize"] == nil, "not in the record")
        mac.sort = .edited; mac.ascending = false
        check(mac.settingsModified > 0)
        phone.textSize = 75
        _ = ps.apply(ms.record())
        eq(phone.sort, .edited); eq(phone.ascending, false); eq(phone.textSize, 75, "the phone keeps its own size")
        // A record an older build wrote, text size included: the size is ignored.
        var old = ms.record(); old["textSize"] = 300; old["t"] = Date().timeIntervalSince1970 + 1
        _ = ps.apply(old)
        eq(phone.textSize, 75)
        // Per device on disk.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        do { let l = Library(store: Store(dir: dir)); l.textSize = 150; l.flush() }
        eq(Library(store: Store(dir: dir)).textSize, 150)
    }
}

// MARK: History

@MainActor func testHistory() {
    group("History: type in A, in B, delete A, undo x3, redo x3") {
        let lib = Library()
        var revealed: [(String, NSRange?)] = []
        lib.history.reveal = { n, r in revealed.append((n.title, r)) }
        let um = lib.history.undoManager
        let a = lib.newNote(), b = lib.newNote(); endEvent()
        typeAtEnd(lib, a, "hello")
        lib.history.breakTyping()   // a click in the list
        typeAtEnd(lib, b, "world")
        lib.delete([a]); endEvent()
        eq(um.undoActionName, "Delete Note")
        um.undo()
        check(lib.contains(a), "A back"); eq(a.text, "hello"); eq(revealed.last?.0, "First Note")
        eq(um.undoActionName, "Typing")
        um.undo()
        eq(b.text, "", "B's typing undone as one step"); eq(a.text, "hello")
        eq(revealed.last?.0, "Second Note"); eq(revealed.last?.1, NSRange(location: 0, length: 0))
        um.undo()
        eq(a.text, "", "A's typing undone"); eq(revealed.last?.0, "First Note")
        eq(um.undoActionName, "New Note")
        um.redo(); eq(a.text, "hello"); eq(revealed.last?.1, NSRange(location: 0, length: 5), "redo selects the text")
        um.redo(); eq(b.text, "world")
        um.redo(); check(!lib.contains(a), "A deleted again")
        check(!um.canRedo)
        um.undo(); check(lib.contains(a))
        // A new edit after an undo clears redo.
        edit(lib, b, NSRange(location: 5, length: 0), "!"); endEvent()
        check(!um.canRedo, "redo cleared by a new edit")
    }

    group("History: coalescing like NSTextView") {
        let lib = Library(); let um = lib.history.undoManager
        let n = lib.newNote(); endEvent()
        typeAtEnd(lib, n, "abcdef")
        backspace(lib, n, at: 6); backspace(lib, n, at: 5)
        typeAtEnd(lib, n, "XY")
        eq(n.text, "abcdXY")
        um.undo(); eq(n.text, "", "typing and Delete inside it: one step")
        um.redo(); eq(n.text, "abcdXY")
        // Delete past the start of the run takes the old text into the same step.
        lib.history.breakTyping()
        typeAtEnd(lib, n, "12")
        for i in stride(from: 8, to: 3, by: -1) { backspace(lib, n, at: i) }
        eq(n.text, "abc")
        um.undo(); eq(n.text, "abcdXY", "run of Delete back past typed text restores the original")
        // Caret moved: two steps.
        lib.history.breakTyping()
        typeAtEnd(lib, n, "1")
        lib.history.breakTyping()
        edit(lib, n, NSRange(location: 0, length: 0), "0"); endEvent()
        eq(n.text, "0abcdXY1")
        um.undo(); eq(n.text, "abcdXY1"); um.undo(); eq(n.text, "abcdXY")
        // Forward Delete run.
        lib.history.breakTyping()
        for _ in 0..<3 { edit(lib, n, NSRange(location: 1, length: 1), ""); endEvent() }
        eq(n.text, "aXY")
        um.undo(); eq(n.text, "abcdXY", "forward deletes: one step")
        // Typing over a selection: a new step that restores the selection.
        lib.history.breakTyping()
        edit(lib, n, NSRange(location: 1, length: 3), "Z"); endEvent()
        typeAtEnd(lib, n, "")   // nothing
        edit(lib, n, NSRange(location: 2, length: 0), "Q"); endEvent()
        eq(n.text, "aZQXY")
        um.undo(); eq(n.text, "abcdXY")
        // Paste and cut are steps of their own, named.
        edit(lib, n, NSRange(location: 6, length: 0), "PASTED", .paste); endEvent()
        eq(um.undoActionName, "Paste")
        edit(lib, n, NSRange(location: 0, length: 2), "", .cut); endEvent()
        eq(um.undoActionName, "Cut")
        typeAtEnd(lib, n, "t")
        eq(n.text, "cdXYPASTEDt")
        um.undo(); eq(n.text, "cdXYPASTED"); um.undo(); eq(n.text, "abcdXYPASTED"); um.undo(); eq(n.text, "abcdXY")
    }

    group("History: marked text (input method) is one step") {
        let lib = Library(); let um = lib.history.undoManager
        let n = lib.newNote(); endEvent()
        typeAtEnd(lib, n, "Hi ")
        lib.history.breakTyping()
        // Japanese: n -> に -> にほ -> にほん -> 日本 committed.
        edit(lib, n, NSRange(location: 3, length: 0), "n"); endEvent()
        edit(lib, n, NSRange(location: 3, length: 1), "に"); endEvent()
        edit(lib, n, NSRange(location: 3, length: 1), "にほ"); endEvent()
        edit(lib, n, NSRange(location: 3, length: 2), "にほん"); endEvent()
        edit(lib, n, NSRange(location: 3, length: 3), "日本"); endEvent()
        eq(n.text, "Hi 日本")
        um.undo(); eq(n.text, "Hi ", "the whole composition at once")
        um.redo(); eq(n.text, "Hi 日本")
        // A cancelled composition leaves nothing to undo: ⌘Z goes past it.
        lib.history.breakTyping()
        edit(lib, n, NSRange(location: 5, length: 0), "k"); endEvent()
        edit(lib, n, NSRange(location: 5, length: 1), ""); endEvent()
        eq(n.text, "Hi 日本")
        um.undo(); eq(n.text, "Hi ", "the empty step is passed over")
        // Emoji (surrogate pairs) typed and deleted.
        lib.history.breakTyping()
        typeAtEnd(lib, n, "😀👍🏽")
        backspace(lib, n, at: n.length)
        eq(n.text, "Hi 😀")
        um.undo(); eq(n.text, "Hi ")
    }

    group("History: a remote change drops only that note's text steps") {
        let lib = Library(); let um = lib.history.undoManager
        let a = lib.newNote(); endEvent()
        let b = lib.newNote(); endEvent()
        typeAtEnd(lib, a, "aaa"); lib.history.breakTyping()
        typeAtEnd(lib, b, "bbb"); lib.history.breakTyping()
        typeAtEnd(lib, a, "AAA")
        lib.applyRemote(a, text: "remote aaaAAA", modified: nil)
        eq(a.text, "remote aaaAAA")
        eq(um.undoActionName, "Typing", "B's typing is next")
        let c = lib.newNote(); endEvent()
        typeAtEnd(lib, c, "c")
        lib.applyRemote(c, text: "C", modified: nil)
        eq(um.undoActionName, "New Note", "the menu names what ⌘Z will do")
        um.undo(); check(!lib.contains(c))
        um.undo(); eq(b.text, "", "B's step undone; A's skipped"); eq(a.text, "remote aaaAAA")
        um.undo()
        eq(lib.notes.count, 1, "next: New Note of B")
        um.undo(); eq(lib.notes.count, 0, "then New Note of A")
        check(!um.canUndo)
        um.redo(); um.redo(); eq(lib.notes.count, 2)
        eq(a.text, "remote aaaAAA", "A's text untouched by redo")
    }

    group("History: leave drops an empty note; undo brings it back with its text") {
        let lib = Library(); let um = lib.history.undoManager
        let a = lib.newNote(), b = lib.newNote(); endEvent()
        typeAtEnd(lib, b, "keep")
        lib.history.breakTyping()
        edit(lib, b, NSRange(location: 0, length: 4), "", .cut); endEvent()   // ⌘A ⌘X
        lib.leave(b)
        check(!lib.contains(b), "dropped silently")
        eq(um.undoActionName, "Cut", "leaving is not an undo step")
        um.undo()
        check(lib.contains(b), "back"); eq(b.text, "keep")
        _ = a
        // An empty new note left at once: its «New Note» is passed over.
        let c = lib.newNote(); endEvent()
        lib.leave(c); check(!lib.contains(c))
        eq(um.undoActionName, "Typing", "the gone note's «New Note» left the stack: the menu names what ⌘Z does")
        um.undo()
        eq(b.text, "", "⌘Z went past the gone note's creation to B's typing")
    }

    group("History: delete several notes, undo, rename, move") {
        let lib = Library(); let um = lib.history.undoManager
        let n = (1...4).map { _ in lib.newNote() }; endEvent()
        lib.delete([n[0], n[2]]); endEvent()
        eq(um.undoActionName, "Delete Notes"); eq(lib.notes.count, 2)
        um.undo(); eq(lib.notes.map(\.title), ["First Note", "Second Note", "Third Note", "Fourth Note"])
        lib.rename(n[1], to: "Plan"); endEvent()
        eq(um.undoActionName, "Rename Note")
        lib.move([n[3]], toIndex: 0); endEvent()
        eq(um.undoActionName, "Move Note")
        eq(lib.notes.first?.title, "Fourth Note")
        um.undo(); eq(lib.notes.first?.title, "First Note")
        um.undo(); eq(n[1].title, "Second Note"); check(!n[1].renamed)
        um.redo(); eq(n[1].title, "Plan")
        um.redo(); eq(lib.notes.first?.title, "Fourth Note")
    }

    group("History: ensureNote's note and the first typing") {
        let lib = Library(); let um = lib.history.undoManager
        let n = lib.ensureNote()
        edit(lib, n, NSRange(location: 0, length: 0), "x"); endEvent()
        um.undo()
        eq(lib.notes.count, 0, "created in the same event as the first key: one undo returns to no notes")
        eq(um.redoActionName, "New Note", "redo named after the creation too")
        um.redo(); eq(lib.notes.first?.text, "x")
        // The same event later changed from another device: the typing step goes, the menu still names the creation.
        let m = lib.notes[0]
        lib.applyRemote(m, text: "remote", modified: nil)
        eq(um.undoActionName, "New Note", "the menu names what ⌘Z will do")
        um.undo(); eq(lib.notes.count, 0)
        // Deleted on another device: its own steps go too, nothing on the stack does nothing.
        let l2 = Library(); let u2 = l2.history.undoManager
        let p = l2.newNote(); endEvent()
        typeAtEnd(l2, p, "p"); l2.history.breakTyping()
        let q = l2.newNote(); endEvent()
        l2.rename(q, to: "Q"); endEvent()
        l2.removeRemote(q)
        eq(u2.undoActionName, "Typing", "Q's New Note and Rename Note left with it")
        u2.undo(); eq(p.text, "")
    }
}

// MARK: History under a storm of undo and redo

/// A small seeded generator, so a failing run can be named by its seed and run again.
struct SeededRandom: RandomNumberGenerator {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A call that does not come back within the bound stops the run with the seed and the operation: a hung ⌘Z must fail
/// the tests, never hang them.
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var since: Date?
    private var what = ""
    init(bound: TimeInterval) {
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock(); let s = since, w = what; lock.unlock()
                if let s, Date().timeIntervalSince(s) > bound {
                    print("  FAIL: \(w) did not return within \(bound) s"); fflush(stdout); exit(1)
                }
            }
        }
    }
    func run<T>(_ w: String, _ f: () -> T) -> T {
        lock.lock(); since = Date(); what = w; lock.unlock()
        defer { lock.lock(); since = nil; lock.unlock() }
        return f()
    }
}

/// Random sequences of every operation the core has (new, typing, cut, delete one or many, leave, rename, move, pin,
/// another device's text change, deletion and new note, ensureNote, caret moves), interleaved with bursts of ⌘Z and
/// ⇧⌘Z. Every call must return within the bound; then everything is undone and redone to the end, which must finish
/// within the stack's depth; without changes from other devices, undoing everything and redoing it must give back
/// exactly the same notes and texts.
@MainActor func testUndoStorm(seeds: Range<UInt64>, steps: Int) {
    let dog = Watchdog(bound: 2)
    group("History: \(seeds.count) random storms of \(steps) steps with undo and redo bursts, a 2 s watchdog on every call") {
        for seed in seeds {
            var g = SeededRandom(seed)
            // One run in four without the silent changes (another device's, an empty note dropped when left), for the
            // round trip check: those are not undo steps, so undoing everything cannot give back the state before them.
            let remote = seed % 4 != 0
            let lib = Library(); let um = lib.history.undoManager
            var calls = 0
            for step in 0..<steps {
                let notes = lib.notes
                let pick = notes.isEmpty ? nil : notes[Int.random(in: 0..<notes.count, using: &g)]
                let r = Int.random(in: 0..<100, using: &g)
                dog.run("seed \(seed) step \(step) op \(r)") {
                    switch r {
                    case 0..<10: _ = lib.newNote()
                    case 10..<25:
                        if let n = pick {
                            var at = Int.random(in: 0...n.length, using: &g)
                            // A text view never puts the caret inside a surrogate pair.
                            if at > 0 && at < n.length && Diff.isLow((n.text as NSString).character(at: at)) { at -= 1 }
                            edit(lib, n, NSRange(location: at, length: 0), ["a", "bc", "é", "😀", "\n"].randomElement(using: &g)!)
                        }
                    case 25..<28:
                        if let n = pick, n.length > 0 {
                            let a = Int.random(in: 0..<n.length, using: &g)
                            let range = (n.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: a, length: min(3, n.length - a)))
                            edit(lib, n, range, "", .cut)
                        }
                    case 28..<31: if let n = pick, n.length > 0 { edit(lib, n, NSRange(location: 0, length: n.length), "", .cut) }
                    case 31..<36: lib.delete(Array(notes.shuffled(using: &g).prefix(Int.random(in: 1...3, using: &g))))
                    case 36..<40: if remote, let n = pick { lib.leave(n) }
                    case 40..<44: if let n = pick { lib.rename(n, to: Bool.random(using: &g) ? "" : "R\(step)") }
                    case 44..<47: if let n = pick { lib.move([n], toIndex: Int.random(in: 0...notes.count, using: &g)) }
                    case 47..<50: if let n = pick { lib.pin([n], Bool.random(using: &g)) }
                    case 50..<53: if remote, let n = pick { lib.applyRemote(n, text: "remote \(step)" as NSString, modified: nil) }
                    case 53..<55: if remote, let n = pick { lib.removeRemote(n) }
                    case 55..<57: if remote { lib.insertRemote(Note(title: "In \(step)", position: Double(step), storage: NSTextStorage(string: Bool.random(using: &g) ? "" : "x"))) }
                    case 57..<60: let n = lib.ensureNote(); edit(lib, n, NSRange(location: 0, length: 0), "e")
                    case 60..<64: lib.history.breakTyping()
                    case 64..<84: for _ in 0..<Int.random(in: 1...20, using: &g) { um.undo(); calls += 1 }
                    default: for _ in 0..<Int.random(in: 1...20, using: &g) { um.redo(); calls += 1 }
                    }
                }
                if ProcessInfo.processInfo.environment["STORM_TRACE"] != nil && step > steps - 12 {
                    print("   step \(step) op \(r): notes \(lib.notes.map { $0.title + "=" + $0.text.debugDescription }) undo «\(um.undoActionName)» canUndo \(um.canUndo) redo «\(um.redoActionName)» canRedo \(um.canRedo)")
                }
                for n in lib.notes { check(n.length == (n.storage.string as NSString).length) }
                if Int.random(in: 0..<3, using: &g) == 0 { endEvent() }
            }
            endEvent()
            // To the top first (the run may end with steps undone), then to the bottom and back: each ⌘Z pops at least
            // one group, so the counts are bounded by what was registered.
            var top = 0
            dog.run("seed \(seed): redo to the top") { while um.canRedo && top < steps * 4 { um.redo(); top += 1 } }
            let before = lib.notes.map { "\($0.id)|\($0.title)|\($0.pinned)|\($0.text)" }.sorted()
            var n = 0
            dog.run("seed \(seed): undo all") { while um.canUndo && n < steps * 4 { um.undo(); n += 1 } }
            check(!um.canUndo, "seed \(seed): undo reaches the bottom")
            var m = 0
            dog.run("seed \(seed): redo all") { while um.canRedo && m < steps * 4 { um.redo(); m += 1 } }
            check(!um.canRedo, "seed \(seed): redo reaches the top")
            if !remote {
                eq(lib.notes.map { "\($0.id)|\($0.title)|\($0.pinned)|\($0.text)" }.sorted(), before, "seed \(seed): undo all + redo all gives back the same notes")
            }
            check(calls > 0)
        }
    }
}

// MARK: Store

@MainActor func testStore() {
    group("Store: round trip, crash leftovers, corrupt and missing files") {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let lib = Library(store: Store(dir: dir))
            let a = lib.newNote(), b = lib.newNote(), c = lib.newNote()
            edit(lib, a, NSRange(location: 0, length: 0), "Привет, мир 😀\nline 2")
            lib.rename(b, to: "Shopping")
            edit(lib, b, NSRange(location: 0, length: 0), "milk")
            lib.sort = .title; lib.ascending = false; lib.textSize = 150
            lib.lastOpen = b.id
            lib.delete([c])
            lib.flush()
        }
        let files = try! FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Notes").path)
        eq(files.count, 2, "deleted note's file removed")
        do {
            let lib = Library(store: Store(dir: dir))
            eq(lib.notes.map(\.title), ["Shopping", "First Note"])
            eq(lib.sort, .title); eq(lib.ascending, false); eq(lib.textSize, 150)
            eq(lib.note(id: lib.lastOpen!)?.title, "Shopping")
            eq(lib.notes.first { $0.title == "First Note" }?.text, "Привет, мир 😀\nline 2")
        }
        // A text file the list never named (crash between the text and the list): kept as a note.
        let orphan = UUID()
        try! Data("orphan text".utf8).write(to: dir.appendingPathComponent("Notes/\(orphan.uuidString).txt"))
        // A file the list names as being removed (crash before the delete): deleted, not resurrected.
        var root = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("notes.json"))) as! [String: Any]
        let ghost = UUID()
        try! Data("ghost".utf8).write(to: dir.appendingPathComponent("Notes/\(ghost.uuidString).txt"))
        root["removing"] = [ghost.uuidString]
        try! JSONSerialization.data(withJSONObject: root).write(to: dir.appendingPathComponent("notes.json"))
        do {
            let lib = Library(store: Store(dir: dir))
            eq(lib.notes.count, 3)
            eq(lib.note(id: orphan)?.text, "orphan text"); eq(lib.note(id: orphan)?.title, "Second Note", "lowest free name")
            check(lib.note(id: ghost) == nil)
            check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Notes/\(ghost.uuidString).txt").path))
        }
        // Invalid UTF-8 and a broken list: every text still there.
        let bad = UUID()
        try! Data([0x61, 0xFF, 0x62]).write(to: dir.appendingPathComponent("Notes/\(bad.uuidString).txt"))
        try! Data("{ not json".utf8).write(to: dir.appendingPathComponent("notes.json"))
        do {
            let lib = Library(store: Store(dir: dir))
            eq(lib.notes.count, 4, "all texts kept with the list broken")
            eq(lib.note(id: bad)?.text, "a\u{FFFD}b")
            check(lib.notes.contains { $0.text == "milk" } && lib.notes.contains { $0.text == "orphan text" })
            eq(Set(lib.notes.map(\.title)).count, 4, "default names, no duplicates")
        }
        // A note in the list with its text file gone: kept (empty), reported for Sync to fetch again.
        do {
            let lib = Library(store: Store(dir: dir))
            let n = lib.notes[0]; lib.flush()
            try! FileManager.default.removeItem(at: dir.appendingPathComponent("Notes/\(n.id.uuidString).txt"))
            let store = Store(dir: dir)
            let lib2 = Library(store: store)
            check(lib2.note(id: n.id) != nil); eq(store.missingText, [n.id])
        }
        // Deleted and brought back before the write: the file stays, its last unwritten edit too.
        do {
            let d3 = tempDir(); defer { try? FileManager.default.removeItem(at: d3) }
            let lib = Library(store: Store(dir: d3))
            let n = lib.newNote(); edit(lib, n, NSRange(location: 0, length: 0), "v1"); endEvent(); lib.flush()
            edit(lib, n, NSRange(location: 2, length: 0), " v2"); endEvent()
            lib.delete([n]); endEvent(); lib.history.undoManager.undo(); lib.flush()
            eq(try? String(contentsOf: d3.appendingPathComponent("Notes/\(n.id.uuidString).txt"), encoding: .utf8), "v1 v2")
            lib.delete([n]); endEvent(); lib.flush()
            lib.history.undoManager.undo(); lib.flush()
            eq(try? String(contentsOf: d3.appendingPathComponent("Notes/\(n.id.uuidString).txt"), encoding: .utf8), "v1 v2", "written again after a real removal")
        }
        // Debounce: nothing written before the delay, written after.
        let d2 = tempDir(); defer { try? FileManager.default.removeItem(at: d2) }
        let store = Store(dir: d2); store.delay = 0.2
        let lib = Library(store: store)
        let n = lib.newNote(); edit(lib, n, NSRange(location: 0, length: 0), "x")
        check(!FileManager.default.fileExists(atPath: d2.appendingPathComponent("notes.json").path), "not yet")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        Thread.sleep(forTimeInterval: 0.1)   // the background write
        check(FileManager.default.fileExists(atPath: d2.appendingPathComponent("Notes/\(n.id.uuidString).txt").path), "written after the delay")
    }
}

// MARK: Diff and Merge

func ns(_ s: String) -> NSString { s as NSString }

func testMerge() {
    group("Diff.minimalReplacement") {
        func r(_ a: String, _ b: String) -> String {
            guard let x = Diff.minimalReplacement(from: ns(a), to: ns(b)) else { return "nil" }
            let applied = ns(a).replacingCharacters(in: x.range, with: x.string)
            eq(applied, b, "applies")
            return "\(x.range.location),\(x.range.length):\(x.string)"
        }
        eq(r("abc", "abc"), "nil")
        eq(r("abc", "abXc"), "2,0:X")
        eq(r("abc", "ac"), "1,1:")
        eq(r("aaa", "aaaa"), "3,0:a")
        eq(r("", "x"), "0,0:x"); eq(r("x", ""), "0,1:")
        eq(r("a😀b", "a😁b"), "1,2:😁", "a surrogate pair is replaced whole")
        eq(r("😀", "😀😀"), "2,0:😀")
        eq(r("x😀", "y😀"), "0,1:y")
        // Random pairs: always applies exactly.
        var g = SystemRandomNumberGenerator()
        let alphabet = Array("ab😀\n é")
        for _ in 0..<2000 {
            let a = String((0..<Int.random(in: 0...12, using: &g)).map { _ in alphabet.randomElement(using: &g)! })
            let b = String((0..<Int.random(in: 0...12, using: &g)).map { _ in alphabet.randomElement(using: &g)! })
            _ = r(a, b)
        }
    }

    group("Merge.threeWay: cases") {
        func m(_ b: String?, _ l: String, _ r: String) -> String { Merge.threeWay(base: b.map(ns), local: ns(l), remote: ns(r)) as String }
        eq(m("a\nb\nc\n", "a\nb\nc\n", "a\nB\nc\n"), "a\nB\nc\n", "only remote changed")
        eq(m("a\nb\nc\n", "A\nb\nc\n", "a\nb\nc\n"), "A\nb\nc\n", "only local changed")
        eq(m("a\nb\nc\n", "A\nb\nc\n", "a\nb\nC\n"), "A\nb\nC\n", "different lines")
        eq(m("one two three", "one 2 three", "one two 3"), "one 2 3", "same line, different words")
        eq(m("a\nb\nc\n", "a\nX\nc\n", "a\nX\nc\n"), "a\nX\nc\n", "same change both")
        eq(m("a\nb\nc\n", "a\nL\nc\n", "a\nR\nc\n"), "a\nL\nR\nc\n", "both changed one line: both versions")
        eq(m("a\nb\nc\n", "a\nc\n", "a\nbb\nc\n"), "a\nbb\nc\n", "deleted here, changed there: the change stays")
        eq(m("hello", "hello world", "hello there"), "hello world there", "both appended")
        eq(m("x\n", "x\nL\n", "x\nR\n"), "x\nL\nR\n", "both added a line at the end")
        eq(m(nil, "abc local", "abc remote"), "abc localremote", "no base: both middles kept")
        eq(m(nil, "same", "same"), "same")
        eq(m("", "L", "R"), "LR")
        eq(m("a😀b", "a😀Lb", "a😀bR"), "a😀LbR", "emoji untouched")
        eq(m("p1\n\np2\n\np3\n", "p1 edited\n\np2\n\np3\n", "p1\n\np2\n\np3 edited\n"), "p1 edited\n\np2\n\np3 edited\n")
        eq(m("abc", "", ""), "")
        eq(m("abc", "", "abcd"), "d", "local deleted what remote left alone: deleted")
        eq(m("abc", "", "abXc"), "abXc", "local deleted what remote changed: the change stays")
    }

    group("Merge.threeWay: random edits never lose an insertion") {
        var g = SystemRandomNumberGenerator()
        let words = ["alpha", "beta", "gamma", "дельта", "😀", "\n", " ", "\n\n", "epsilon"]
        for round in 0..<600 {
            let base = (0..<Int.random(in: 0...60, using: &g)).map { _ in words.randomElement(using: &g)! }.joined()
            var marker = 0
            func mutate(_ s: String, _ tag: String) -> (String, [String]) {
                var t = s as NSString
                var added: [String] = []
                for _ in 0..<Int.random(in: 1...4, using: &g) {
                    let len = t.length
                    var at = Int.random(in: 0...len, using: &g)
                    if at > 0 && at < len && Diff.isLow(t.character(at: at)) { at -= 1 }
                    // Not inside a marker: the check looks for each one whole.
                    let before = t.substring(to: at)
                    if before.filter({ $0 == "⟨" }).count != before.filter({ $0 == "⟩" }).count { continue }
                    if Bool.random(using: &g) || len == 0 {
                        marker += 1
                        let m = "⟨\(tag)\(round).\(marker)⟩"
                        t = t.replacingCharacters(in: NSRange(location: at, length: 0), with: m) as NSString
                        added.append(m)
                    } else {
                        let r = t.rangeOfComposedCharacterSequences(for: NSRange(location: at, length: min(Int.random(in: 1...6, using: &g), len - at)))
                        // Never delete inside a marker of this side: keeps the check simple.
                        let cut = t.substring(with: r)
                        if cut.contains("⟨") || cut.contains("⟩") || added.contains(where: { t.range(of: $0).intersection(r) != nil }) { continue }
                        t = t.replacingCharacters(in: r, with: "") as NSString
                    }
                }
                return (t as String, added)
            }
            let (l, la) = mutate(base, "L"), (r, ra) = mutate(base, "R")
            let out = Merge.threeWay(base: ns(base), local: ns(l), remote: ns(r)) as String
            for mk in la + ra { check(out.contains(mk), "round \(round): \(mk) lost\nbase \(base.debugDescription)\nL \(l.debugDescription)\nR \(r.debugDescription)\nout \(out.debugDescription)") }
            check(out.unicodeScalars.allSatisfy { !(0xD800...0xDFFF).contains($0.value) }, "no broken surrogates")
            if l == base { eq(out, r) }
            if r == base { eq(out, l) }
        }
    }
}

// MARK: Sync against an in-memory CloudKit

/// The server: records with versions, a change log for tokens, switches for the failures CloudKit can give.
final class FakeServer: @unchecked Sendable {
    var records: [UUID: CloudNote] = [:]
    var version: [UUID: Int] = [:]
    var log: [(seq: Int, id: UUID)] = []
    var seq = 0
    var zone = true
    var expiredBefore = 0
    var pageSize = 1000
    /// Errors the next whole operations throw, in order (fetch, modify).
    var failFetch: [CloudError] = []
    var failModify: [CloudError] = []
    /// Texts over this many UTF-16 units come down without their text (an asset not downloaded).
    var assetLimit = Int.max
    /// Deletions the next fetch reports although the records are there (a stale tombstone, a record made again).
    var staleDeletions: [UUID] = []
    var modifies = 0, savedTexts = 0

    func bump(_ id: UUID) { seq += 1; log.append((seq, id)) }
}

final class FakeDevice: CloudDatabase, @unchecked Sendable {
    let server: FakeServer
    var accountState: CloudAccount = .available(userID: "user-1")
    init(_ s: FakeServer) { server = s }

    func account() async -> CloudAccount { accountState }
    func ensureZone() async throws { server.zone = true }
    func ensureSubscription() async throws {}

    func fetchChanges(since token: Data?) async throws -> ZoneChanges {
        if !server.failFetch.isEmpty { throw server.failFetch.removeFirst() }
        guard server.zone else { throw CloudError.zoneNotFound }
        let from = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        if token != nil && from < server.expiredBefore { throw CloudError.tokenExpired }
        let later = server.log.filter { $0.seq > from }
        var out = ZoneChanges()
        var seen = Set<UUID>()
        var last = from
        for e in later {
            if seen.count >= server.pageSize { out.more = true; break }
            last = e.seq
            guard seen.insert(e.id).inserted else { continue }
            // The latest state of the record, as CloudKit gives it.
            if var r = server.records[e.id] {
                if let t = r.text, t.length > server.assetLimit { r.text = nil }
                out.changed.append(r)
            } else { out.deleted.append(e.id) }
        }
        out.token = Data(String(last).utf8)
        out.deleted += server.staleDeletions; server.staleDeletions = []
        return out
    }

    func fetch(_ ids: [UUID]) async throws -> [UUID: CloudNote] {
        var out: [UUID: CloudNote] = [:]
        for id in ids {
            out[id] = server.records[id]
            if let t = out[id]?.text, t.length > server.assetLimit { out[id]?.text = nil }
        }
        return out
    }

    func modify(save: [CloudNote], delete: [UUID]) async throws -> (saved: [UUID: SaveOutcome], deleted: [UUID: CloudError?]) {
        server.modifies += 1
        if !server.failModify.isEmpty { throw server.failModify.removeFirst() }
        guard server.zone else { throw CloudError.zoneNotFound }
        var saved: [UUID: SaveOutcome] = [:], deleted: [UUID: CloudError?] = [:]
        for n in save {
            if let current = server.records[n.id] {
                // CloudKit's ifServerRecordUnchanged: the client must name the server's current change tag.
                guard n.tag == current.tag else { saved[n.id] = .conflict(server: current); continue }
                var r = n
                if r.text == nil { r.text = current.text } else { server.savedTexts += 1 }
                server.version[n.id, default: 0] += 1
                r.tag = "v\(server.version[n.id]!)"; r.meta = Data(r.tag!.utf8)
                server.records[n.id] = r; server.bump(n.id)
                saved[n.id] = .saved(meta: r.meta, tag: r.tag)
            } else if n.tag != nil {
                saved[n.id] = .gone
            } else {
                var r = n
                if r.text == nil { r.text = "" } else { server.savedTexts += 1 }
                server.version[n.id] = (server.version[n.id] ?? 0) + 1
                r.tag = "v\(server.version[n.id]!)"; r.meta = Data(r.tag!.utf8)
                server.records[n.id] = r; server.bump(n.id)
                saved[n.id] = .saved(meta: r.meta, tag: r.tag)
            }
        }
        for id in delete {
            if server.records.removeValue(forKey: id) != nil { server.bump(id) }
            deleted[id] = .some(nil)
        }
        return (saved, deleted)
    }
}

@MainActor final class Device {
    let lib: Library
    let db: FakeDevice
    let sync: Sync
    var errors: [CloudError] = []
    init(_ server: FakeServer, dir: URL? = nil) {
        lib = Library(store: dir.map { Store(dir: $0) })
        db = FakeDevice(server)
        sync = Sync(library: lib, database: db)
        sync.autorun = false
        sync.anyFolder = true
        sync.onRunEnded = { [weak self] e in if let e { self?.errors.append(e) } }
        sync.start()
    }
    func run() async { await sync.run() }
    func note(_ title: String) -> Note? { lib.notes.first { $0.title == title } }
}

@MainActor func settle(_ devices: [Device]) async {
    for _ in 0..<4 { for d in devices { d.sync.fetchNow(); await d.run() } }
}

@MainActor func testSync() async {
    await agroup("Sync: create, edit, rename, move, delete travel between two devices") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote()
        edit(a.lib, n, NSRange(location: 0, length: 0), "from A")
        await settle([a, b])
        eq(b.lib.notes.count, 1); eq(b.lib.notes.first?.text, "from A"); eq(b.lib.notes.first?.title, "First Note")
        let nb = b.lib.notes[0]
        edit(b.lib, nb, NSRange(location: 6, length: 0), ", and B")
        b.lib.rename(nb, to: "Shared")
        await settle([a, b])
        eq(n.text, "from A, and B"); eq(n.title, "Shared"); check(n.renamed)
        let m = a.lib.newNote()
        a.lib.move([m], toIndex: 0)
        await settle([a, b])
        eq(b.lib.notes.map(\.title), ["First Note", "Shared"], "order follows")
        a.lib.pin([m], true)
        await settle([a, b])
        eq(b.lib.notes.first?.pinned, true, "pinned follows"); eq(b.lib.notes.first?.title, "First Note")
        a.lib.delete([m])
        await settle([a, b])
        eq(b.lib.notes.map(\.title), ["Shared"])
        check(a.sync.idle && b.sync.idle)
        eq(a.errors + b.errors, [])
    }

    await agroup("Sync: the caret's text stays, minimal replacement, undo steps of that note dropped") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote(); endEvent()
        edit(a.lib, n, NSRange(location: 0, length: 0), "line one\nline two\nline three\n"); endEvent()
        await settle([a, b])
        let nb = b.lib.notes[0]
        var changes: [Library.Change] = []
        let o = NotificationCenter.default.addObserver(forName: Library.didChange, object: a.lib, queue: nil) { changes.append($0.userInfo![Library.changeKey] as! Library.Change) }
        edit(b.lib, nb, NSRange(location: 14, length: 0), "2 ")
        await settle([a, b])
        NotificationCenter.default.removeObserver(o)
        eq(n.text, "line one\nline 2 two\nline three\n")
        let ranges = changes.compactMap { if case .text(_, let r, let d) = $0 { return (r, d) } else { return nil } }
        eq(ranges.count, 1); eq(ranges.first?.0, NSRange(location: 14, length: 2)); eq(ranges.first?.1, 2)
        a.lib.history.undoManager.undo()
        eq(a.lib.notes.count, 0, "A's typing left the history: the undo removes the note, not B's text")
    }

    await agroup("Sync: concurrent edits merge three ways, offline edits catch up") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote()
        edit(a.lib, n, NSRange(location: 0, length: 0), "alpha\nbeta\ngamma\n")
        await settle([a, b])
        let nb = b.lib.notes[0]
        // Both offline, both edit.
        a.db.accountState = .unavailable; b.db.accountState = .unavailable
        edit(a.lib, n, NSRange(location: 0, length: 5), "ALPHA")
        edit(b.lib, nb, NSRange(location: 11, length: 5), "GAMMA")
        await a.run(); await b.run()
        eq(server.records[n.id]?.text, "alpha\nbeta\ngamma\n", "nothing went while offline")
        a.db.accountState = .available(userID: "user-1"); b.db.accountState = .available(userID: "user-1")
        // The account came back: CKAccountChanged.
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        await settle([a, b])
        eq(n.text, "ALPHA\nbeta\nGAMMA\n"); eq(nb.text, "ALPHA\nbeta\nGAMMA\n")
        // Same line on both: both versions.
        edit(a.lib, n, NSRange(location: 6, length: 4), "BETA-A")
        edit(b.lib, nb, NSRange(location: 6, length: 4), "BETA-B")
        await a.run(); await b.run(); await settle([a, b])
        eq(n.text, nb.text); check(n.text.contains("BETA-A") && n.text.contains("BETA-B"), n.text)
        eq(a.errors.filter { $0 != .notAuthenticated } + b.errors.filter { $0 != .notAuthenticated }, [])
    }

    await agroup("Sync: a big merge runs off the main thread; typing during it is kept") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote()
        let base = (0..<20_000).map { "line \($0) of the big note" }.joined(separator: "\n")
        edit(a.lib, n, NSRange(location: 0, length: 0), base)
        await settle([a, b])
        let nb = b.lib.notes[0]
        edit(b.lib, nb, NSRange(location: nb.length - 4, length: 4), "NOTE FROM B")
        await b.run()
        a.db.accountState = .unavailable
        edit(a.lib, n, NSRange(location: 0, length: 4), "LINE"); await a.run()
        a.db.accountState = .available(userID: "user-1"); NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        a.sync.fetchNow()
        let job = Task { await a.run() }
        var typed = 0
        for _ in 0..<40 {
            await Task.yield()
            edit(a.lib, n, NSRange(location: 0, length: 0), "K"); typed += 1
        }
        await job.value
        check(n.text.hasPrefix(String(repeating: "K", count: typed) + "LINE 0"), String(n.text.prefix(60)))
        check(n.text.hasSuffix("big NOTE FROM B"), String(n.text.suffix(30)))
        await settle([a, b])
        eq(nb.text, n.text)
    }

    await agroup("Sync: a fresh client deletes nothing it was not told to") {
        let server = FakeServer()
        let a = Device(server)
        for i in 0..<6 {
            let n = a.lib.newNote(); edit(a.lib, n, NSRange(location: 0, length: 0), i == 0 ? "Осиль… Тильд… Оро" : "note \(i)")
        }
        let empty = a.lib.newNote()   // an empty note A has open, about to be typed into
        a.lib.lastOpen = empty.id
        await settle([a])
        var all = Set(server.records.keys)
        eq(all.count, 7)
        func intact(_ what: String, line: Int = #line) { eq(Set(server.records.keys), all, what, line: line) }
        // 1. A fresh client (empty store, new sync.json) that only fetches and looks around.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let b = Device(server, dir: dir)
        await settle([b])
        eq(b.lib.notes.count, 7)
        for n in b.lib.notes { b.lib.lastOpen = n.id; b.lib.leave(n) }   // clicking through every note
        b.lib.flush(); await settle([b])
        intact("clicking through, the empty note from A included")
        check(b.lib.note(id: empty.id) != nil, "A's empty note is not dropped on B")
        // 2. Its own empty note, made before the first fetch, left: nothing of A's goes.
        let c = Device(server)
        let own = c.lib.ensureNote(); _ = c.lib.newNote()
        await settle([c])
        c.lib.leave(own)
        await settle([c])
        all.formUnion(c.lib.notes.map(\.id))   // C's other note went up: added, nothing deleted
        intact("a fresh client's own empty note dropped")
        // 3. Select-all delete while the first fetch is still coming in pages: only what it held goes.
        server.pageSize = 2
        let d = Device(server)
        d.sync.fetchNow()
        d.db.accountState = .available(userID: "user-1")
        server.failFetch = []
        // One page only: the fetch is cut by a network error after it.
        let firstPage = try! await d.db.fetchChanges(since: nil)
        for r in firstPage.changed { await d.sync.receive(r) }
        let held = Set(d.lib.notes.map(\.id))
        eq(held.count, 2)
        d.lib.delete(d.lib.notes); endEvent()
        await settle([d])
        eq(Set(server.records.keys), all.subtracting(held), "only the two it held and the person deleted")
        server.pageSize = 1000
        d.lib.history.undoManager.undo()
        await settle([d])
        intact("undo brings them back")
        // 4. Zone made again, token reset, another account: no record deleted.
        let e = Device(server)
        await settle([e])
        server.expiredBefore = server.seq + 1
        await settle([e])
        intact("token expired")
        server.zone = false
        await settle([e])
        eq(Set(server.records.keys).isSuperset(of: Set(e.lib.notes.map(\.id))), true)
        e.db.accountState = .available(userID: "user-2")
        await settle([e])
        e.db.accountState = .available(userID: "user-1")
        await settle([e, a])
        check(Set(server.records.keys).isSuperset(of: Set(a.lib.notes.map(\.id))), "all of A's notes still there")
        // 5. A note whose text file was lost here is never dropped as empty, and gets its text back.
        let dir2 = tempDir(); defer { try? FileManager.default.removeItem(at: dir2) }
        var f: Device? = Device(server, dir: dir2)
        await settle([f!])
        let lost = f!.lib.notes.first { $0.text == "note 1" }!.id
        f!.lib.flush(); f = nil
        try! FileManager.default.removeItem(at: dir2.appendingPathComponent("Notes/\(lost.uuidString).txt"))
        let f2 = Device(server, dir: dir2)
        let shell = f2.lib.note(id: lost)!
        f2.lib.lastOpen = shell.id
        _ = f2.lib.notes.first { $0.id != lost }.map { f2.lib.lastOpen = $0.id }
        f2.lib.leave(shell)
        check(f2.lib.contains(shell), "not dropped while its text is missing")
        await settle([f2])
        eq(shell.text, "note 1"); check(server.records[lost] != nil)
        // 6. A copy on a scratch folder does not sync unless told to.
        let dir3 = tempDir(); defer { try? FileManager.default.removeItem(at: dir3) }
        let g = Library(store: Store(dir: dir3))
        let gs = Sync(library: g, database: FakeDevice(server))
        gs.autorun = false
        gs.start(); await gs.run()
        eq(g.notes.count, 0, "nothing fetched into a scratch folder"); check(g.sync == nil)
    }

    await agroup("Sync: ⌘A ⌘⌫ then ⌘Z before the deletes went sends nothing") {
        let server = FakeServer()
        let a = Device(server)
        for i in 0..<5 { let n = a.lib.newNote(); edit(a.lib, n, NSRange(location: 0, length: 0), "n\(i)") }
        endEvent(); await a.run()
        let unsynced = a.lib.notes[0]
        a.db.accountState = .unavailable
        edit(a.lib, unsynced, NSRange(location: 0, length: 0), "edited "); await a.run()
        a.db.accountState = .available(userID: "user-1"); NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        let before = server.savedTexts
        a.lib.delete(a.lib.notes); endEvent()
        a.lib.history.undoManager.undo()
        await a.run()
        eq(server.records.count, 5, "nothing deleted")
        eq(server.savedTexts - before, 1, "only the edit that waited goes up")
        eq(server.records[unsynced.id]?.text, "edited n0")
        check(a.sync.idle)
        // Deleted for real, then undone: up again as new records; then nothing waits.
        a.lib.delete(a.lib.notes); endEvent(); await a.run()
        eq(server.records.count, 0); check(a.sync.idle, "nothing left waiting for deleted notes")
        a.lib.history.undoManager.undo(); await a.run()
        eq(server.records.count, 5); check(a.sync.idle)
    }

    await agroup("Sync: a newer text that has not come down blocks uploads and deletes of that note") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote(); edit(a.lib, n, NSRange(location: 0, length: 0), "line one\nline two\n"); endEvent()
        await settle([a, b])
        let nb = b.lib.note(id: n.id)!
        // B edits offline; A changes another line; its text then fails to come down to B.
        b.db.accountState = .unavailable
        edit(b.lib, nb, NSRange(location: 0, length: 4), "LINE"); await b.run()
        edit(a.lib, n, NSRange(location: 9, length: 4), "LINE"); await a.run()
        server.assetLimit = 5
        b.db.accountState = .available(userID: "user-1"); NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        await b.run()
        eq(server.records[n.id]?.text, "line one\nLINE two\n", "B's upload waited: A's text not overwritten")
        // B deletes it meanwhile: the delete waits too.
        b.lib.delete([nb]); endEvent(); await b.run()
        check(server.records[n.id] != nil, "not deleted unseen")
        server.assetLimit = .max
        await settle([a, b])
        eq(b.lib.note(id: n.id)?.text, "line one\nLINE two\n", "A's change wins over the delete it had not seen")
        // And without the delete: an unsynced edit merges once the text comes.
        let m = a.lib.newNote(); edit(a.lib, m, NSRange(location: 0, length: 0), "a\nb\n"); endEvent()
        await settle([a, b])
        let mb = b.lib.note(id: m.id)!
        b.db.accountState = .unavailable
        edit(b.lib, mb, NSRange(location: 0, length: 1), "A"); await b.run()
        edit(a.lib, m, NSRange(location: 2, length: 1), "B"); await a.run()
        server.assetLimit = 1
        b.db.accountState = .available(userID: "user-1"); NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        await b.run()
        eq(server.records[m.id]?.text, "a\nB\n")
        server.assetLimit = .max
        await settle([a, b])
        eq(mb.text, "A\nB\n"); eq(server.records[m.id]?.text, "A\nB\n")
    }

    await agroup("Sync: impossible numbers from iCloud are not taken") {
        let server = FakeServer()
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = Device(server)
        let n = a.lib.newNote(); edit(a.lib, n, NSRange(location: 0, length: 0), "x"); await a.run()
        let b = Device(server, dir: dir)
        await settle([b])
        for bad in [Double.infinity, -.infinity, .nan, 1e300] {
            server.records[n.id]!.position = bad
            server.records[n.id]!.created = Date(timeIntervalSinceReferenceDate: .nan)
            server.records[n.id]!.modified = Date(timeIntervalSinceReferenceDate: .infinity)
            server.version[n.id]! += 1; server.records[n.id]!.tag = "v\(server.version[n.id]!)"; server.bump(n.id)
            b.sync.fetchNow(); await b.run()
            let nb = b.lib.note(id: n.id)!
            check(nb.position.isFinite && nb.created.timeIntervalSinceReferenceDate.isFinite && nb.modified.timeIntervalSinceReferenceDate.isFinite, "\(bad)")
            b.lib.flush()   // writing notes.json must not stop the process
        }
        // A note new to this device with such numbers: placed last, dated now.
        let fresh = UUID()
        server.records[fresh] = CloudNote(id: fresh, title: "Odd", created: Date(timeIntervalSinceReferenceDate: .nan), modified: .distantFuture,
                                          position: .nan, renamed: true, text: "odd", meta: Data("v1".utf8), tag: "v1")
        server.version[fresh] = 1; server.bump(fresh)
        b.sync.fetchNow(); await b.run()
        let o = b.lib.note(id: fresh)!
        check(o.position.isFinite && o.modified < Date().addingTimeInterval(60)); eq(b.lib.notes.last?.id, fresh)
        b.lib.flush()
        // notes.json with impossible numbers (written by anything) loads repaired.
        var root = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("notes.json"))) as! [String: Any]
        var list = root["notes"] as! [[String: Any]]
        list[0]["position"] = 1e300; list[0]["created"] = -1e300
        root["notes"] = list
        try! JSONSerialization.data(withJSONObject: root).write(to: dir.appendingPathComponent("notes.json"))
        let l = Library(store: Store(dir: dir))
        check(l.notes.allSatisfy { abs($0.position) <= 1e12 && $0.created.timeIntervalSinceReferenceDate >= 0 }); l.flush()
    }

    await agroup("Sync: a deletion from the server is checked before a note goes") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote(); edit(a.lib, n, NSRange(location: 0, length: 0), "still here"); endEvent()
        await settle([a, b])
        // A stale deletion for a record that is there: the note stays.
        server.staleDeletions = [n.id]
        b.sync.fetchNow(); await b.run()
        eq(b.lib.note(id: n.id)?.text, "still here", "the record is there: kept")
        // Changed and deleted in one fetch (made again by an undo somewhere): kept, with the change.
        edit(a.lib, n, NSRange(location: 0, length: 0), "again: "); await a.run()
        server.staleDeletions = [n.id]
        b.sync.fetchNow(); await b.run()
        eq(b.lib.note(id: n.id)?.text, "again: still here")
        // A real deletion still takes it.
        a.lib.delete([n]); endEvent(); await a.run()
        b.sync.fetchNow(); await b.run()
        check(b.lib.note(id: n.id) == nil, "truly gone: goes")
    }

    await agroup("Sync: a delete never removes a version it did not see; unsynced edits survive a delete") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote(); edit(a.lib, n, NSRange(location: 0, length: 0), "v1"); endEvent()
        await settle([a, b])
        let nb = b.lib.notes[0]
        // B's edit reaches iCloud; A deletes before it has fetched it.
        edit(b.lib, nb, NSRange(location: 2, length: 0), " + B's newer text")
        await b.run()
        a.lib.delete([n]); endEvent()
        await a.run()
        eq(server.records[n.id]?.text, "v1 + B's newer text", "not deleted")
        eq(a.lib.note(id: n.id)?.text, "v1 + B's newer text", "back on A with B's text")
        // Unsynced edits on B, A deletes, B uploads before it fetches (the server says gone): B's note goes up again.
        await settle([a, b])
        b.db.accountState = .unavailable
        edit(b.lib, nb, NSRange(location: 0, length: 0), "offline: ")
        await b.run()
        let na = a.lib.note(id: n.id)!
        a.lib.delete([na]); endEvent()
        await a.run()
        check(server.records[n.id] == nil, "deleted: A had the latest version")
        b.db.accountState = .available(userID: "user-1")
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        await b.run()
        eq(server.records[n.id]?.text, "offline: v1 + B's newer text", "B's unsynced edit kept and up again")
        await settle([a, b])
        eq(a.lib.note(id: n.id)?.text, "offline: v1 + B's newer text", "and back on A")
    }

    await agroup("Sync: in front, a fetch every 15 s") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        a.sync.autorun = true
        eq(a.sync.pollInterval, 15)
        let n = b.lib.newNote(); edit(b.lib, n, NSRange(location: 0, length: 0), "from B"); await b.run()
        a.sync.pollInterval = 0.3
        a.sync.setForeground(true)
        // The first fetch goes at once.
        for _ in 0..<10 where a.lib.notes.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        eq(a.lib.notes.first?.text, "from B")
        // Then again by itself, with no push.
        edit(b.lib, n, NSRange(location: 6, length: 0), " again"); await b.run()
        for _ in 0..<50 where a.lib.notes.first?.text != "from B again" { try? await Task.sleep(nanoseconds: 20_000_000) }
        eq(a.lib.notes.first?.text, "from B again")
        a.sync.setForeground(false)
        edit(b.lib, n, NSRange(location: 0, length: 0), "> "); await b.run()
        try? await Task.sleep(nanoseconds: 700_000_000)
        eq(a.lib.notes.first?.text, "from B again", "behind: no polling")
    }

    await agroup("Sync: delete vs edit, undo of a delete after it reached iCloud") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        let n = a.lib.newNote()
        edit(a.lib, n, NSRange(location: 0, length: 0), "precious"); endEvent()
        await settle([a, b])
        let nb = b.lib.notes[0]
        // A deletes; B edits before hearing of it: the edit wins.
        a.lib.delete([n]); endEvent()
        edit(b.lib, nb, NSRange(location: 8, length: 0), " text")
        await a.run()
        check(server.records[n.id] == nil)
        await settle([a, b])
        check(b.lib.contains(nb), "kept on B"); eq(nb.text, "precious text")
        eq(a.lib.notes.first?.text, "precious text", "and back on A")
        // Undo of a delete whose record is gone: goes up as a new record.
        let c = a.lib.notes[0]
        a.lib.delete([c]); endEvent()
        await settle([a, b])
        eq(b.lib.notes.count, 0)
        a.lib.history.undoManager.undo()
        check(a.lib.contains(c))
        await settle([a, b])
        eq(b.lib.notes.first?.text, "precious text", "restored note re-uploaded")
        // Delete then undo before the delete went: nothing lost, nothing sent twice.
        a.lib.delete([c]); a.lib.history.undoManager.undo()
        await settle([a, b])
        eq(b.lib.notes.count, 1)
    }

    await agroup("Sync: token expired, zone deleted, rate limit, batch too big, account switched") {
        let server = FakeServer()
        let a = Device(server), b = Device(server)
        for i in 0..<5 { let n = a.lib.newNote(); edit(a.lib, n, NSRange(location: 0, length: 0), "note \(i)") }
        await settle([a, b])
        eq(b.lib.notes.count, 5)
        // Token expired: everything fetched again, nothing duplicated.
        server.expiredBefore = server.seq + 1
        edit(a.lib, a.lib.notes[0], NSRange(location: 0, length: 0), ">")
        await a.run()
        server.expiredBefore = server.seq + 1
        await settle([b])
        eq(b.lib.notes.count, 5); eq(b.lib.notes[0].text, ">note 0")
        // Zone deleted (iCloud settings): made again, every note goes up again.
        server.zone = false; server.records = [:]; server.log = []
        await settle([a, b])
        eq(server.records.count, 5, "all notes up again"); eq(b.lib.notes.count, 5)
        // Rate limit: the run ends with the wait CloudKit named, and the next run goes.
        server.failModify = [.retryAfter(30)]
        edit(a.lib, a.lib.notes[1], NSRange(location: 0, length: 0), "!")
        a.errors = []
        await a.run()
        eq(a.errors, [.retryAfter(30)])
        check(server.records[a.lib.notes[1].id]?.text == "note 1")
        await a.run()
        eq(server.records[a.lib.notes[1].id]?.text, "!note 1")
        // Batch too big: halved until it goes.
        server.failModify = [.limitExceeded, .limitExceeded]
        for n in a.lib.notes { edit(a.lib, n, NSRange(location: 0, length: 0), "#") }
        a.errors = []
        await a.run()
        eq(a.errors, []); check(a.lib.notes.allSatisfy { (server.records[$0.id]?.text as String?) == $0.text }, "all went")
        // Another account: starts over, the notes here go up to it.
        let other = FakeServer()
        let c = Device(other)
        let cn = c.lib.newNote(); edit(c.lib, cn, NSRange(location: 0, length: 0), "c")
        await c.run()
        c.db.accountState = .available(userID: "user-2")
        let c2db = FakeDevice(server); _ = c2db
        await c.run()
        eq(other.records[cn.id]?.text, "c")
    }

    await agroup("Sync: big text as a file, a record whose file did not come, many notes in pages") {
        let server = FakeServer()
        server.pageSize = 3
        let a = Device(server), b = Device(server)
        let big = String(repeating: "Война и мир. ", count: 100_000)   // 1.3 M characters, ~2.4 MB of UTF-8
        let n = a.lib.newNote()
        edit(a.lib, n, NSRange(location: 0, length: 0), big)
        for i in 0..<10 { let m = a.lib.newNote(); edit(a.lib, m, NSRange(location: 0, length: 0), "small \(i)") }
        server.assetLimit = 1000
        await settle([a])
        await b.run()
        eq(b.lib.notes.count, 10, "the big note waits for its file")
        server.assetLimit = .max
        await settle([b])
        eq(b.lib.notes.count, 11); eq(b.lib.note(id: n.id)?.length, (big as NSString).length)
        // A rename of the big note sends no text.
        let before = server.savedTexts
        a.lib.rename(n, to: "Tolstoy")
        await a.run()
        eq(server.savedTexts, before, "fields only")
        await settle([b]); eq(b.lib.note(id: n.id)?.title, "Tolstoy")
    }

    await agroup("Sync: state survives a quit (dirty notes, bases, token)") {
        let server = FakeServer()
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var a: Device? = Device(server, dir: dir)
        let b = Device(server)
        let n = a!.lib.newNote(); edit(a!.lib, n, NSRange(location: 0, length: 0), "one\ntwo\nthree\n")
        await settle([a!, b])
        let id = n.id
        // A edits offline and quits; B edits another line meanwhile.
        a!.db.accountState = .unavailable
        edit(a!.lib, n, NSRange(location: 0, length: 3), "ONE")
        await a!.run()
        a!.lib.flush(); a = nil
        let nb = b.lib.notes[0]
        edit(b.lib, nb, NSRange(location: 8, length: 5), "THREE")
        await settle([b])
        let a2 = Device(server, dir: dir)
        await settle([a2, b])
        eq(a2.lib.note(id: id)?.text, "ONE\ntwo\nTHREE\n", "merged with the base kept on disk")
        eq(nb.text, "ONE\ntwo\nTHREE\n")
    }
}


// MARK: Paste

/// A picture of text, as a screenshot would be.
func card(_ text: String, points: CGFloat = 26) -> CGImage {
    let a = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: points), .foregroundColor: NSColor.black])
    let s = a.boundingRect(with: NSSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin]).size
    let size = NSSize(width: ceil(s.width) + 80, height: ceil(s.height) + 60)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
    a.draw(in: NSRect(x: 40, y: 30, width: s.width + 2, height: s.height + 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

@MainActor func testPaste() async {
    await agroup("Paste: files, text, rich text, PDF, colour, picture through Vision") {
        let pb = NSPasteboard(name: NSPasteboard.Name("merum-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        // Files as Finder copies them: URLs plus their names as strings; the paths win.
        pb.clearContents()
        let f1 = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), f2 = URL(fileURLWithPath: "/etc/hosts")
        pb.writeObjects([f1 as NSURL, f2 as NSURL])
        eq(Paste.content(of: pb), .text("/System/Library/CoreServices/Finder.app\n/etc/hosts"))
        pb.clearContents(); pb.setString("plain ✓ текст", forType: .string)
        eq(Paste.content(of: pb), .text("plain ✓ текст"))
        // Rich text with no plain string beside it.
        pb.clearContents()
        let rich = NSAttributedString(string: "bold words", attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .link: URL(string: "https://example.com")!])
        pb.setData(try! rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        eq(Paste.content(of: pb), .text("bold words"))
        pb.clearContents(); pb.setData(Data("<p>Hello <b>web</b> &amp; more</p>".utf8), forType: .html)
        if case .text(let s) = Paste.content(of: pb) { eq(s.trimmingCharacters(in: .whitespacesAndNewlines), "Hello web & more") } else { check(false, "html") }
        // A web link that is not a file.
        pb.clearContents(); pb.writeObjects([URL(string: "https://example.com/a?b=c")! as NSURL])
        // NSURL writes a string form too; either way the address comes out.
        eq(Paste.content(of: pb), .text("https://example.com/a?b=c"))
        // A colour from the colour panel.
        pb.clearContents(); pb.writeObjects([NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)])
        eq(Paste.content(of: pb), .text("#FF8000"))
        // A PDF with text.
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 100)
        let ctx = CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "PDF words", attributes: [.font: NSFont.systemFont(ofSize: 18)]).draw(at: NSPoint(x: 10, y: 40))
        NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage(); ctx.closePDF()
        pb.clearContents(); pb.setData(pdfData as Data, forType: .pdf)
        if case .text(let s) = Paste.content(of: pb) { check(s.contains("PDF words"), s) } else { check(false, "pdf") }
        // A screenshot straight to the clipboard: PNG only.
        let text = "Ещё вчера съёмка шла по плану\nThe quick brown fox jumps"
        let image = card(text)
        pb.clearContents()
        pb.setData(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!, forType: .png)
        guard case .image(let got) = Paste.content(of: pb) else { check(false, "image"); return }
        eq(got.width, image.width)
        let t = Date()
        let read = await Paste.recognize(got)
        print("    Vision read the card in \(ms(t)) (the first time includes Vision's model preparation)")
        eq(read, text)
        let t2 = Date(); _ = await Paste.recognize(got); print("    again: \(ms(t2))")
        // ⌘V held down on one copy: one decode (the same CGImage each time) and one Vision reading for all of them at
        // once, each paste still getting the text (stress matrix 2026-11-27: 205 readings at once, 190 MB → 2.6 GB).
        if case .image(let same) = Paste.content(of: pb) { check(same === got, "one decode per copy") } else { check(false, "image again") }
        let t3 = Date()
        let many = await withTaskGroup(of: String.self) { g in
            for _ in 0..<50 { g.addTask { await Paste.recognize(got) } }
            var all: [String] = []; for await s in g { all.append(s) }; return all
        }
        print("    50 at once: \(ms(t3))")
        eq(many, Array(repeating: text, count: 50))
        // A picture with no text: nothing to put in.
        eq(await Paste.recognize(card(" ")), "")
        // HTML is read offline: nothing it names is fetched (a listener counts any connection).
        let listener = try! NWListener(using: .tcp, on: .any)
        final class Count: @unchecked Sendable { var n = 0 }
        let hits = Count()
        listener.newConnectionHandler = { c in hits.n += 1; c.cancel() }
        listener.start(queue: .global())
        for _ in 0..<100 where listener.port == nil || listener.port!.rawValue == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let port = listener.port!.rawValue
        let page = """
            <!DOCTYPE html><html><head><title>T</title><link rel=stylesheet href="http://127.0.0.1:\(port)/a.css">
            <style>body{background:url(http://127.0.0.1:\(port)/bg.png)} @import url(http://127.0.0.1:\(port)/b.css);</style>
            <script src="http://127.0.0.1:\(port)/s.js"></script></head>
            <body><h1>Title &amp; more</h1><p>Hello   <b>web</b>&nbsp;page.<br>Line&#160;two &#x2014; &laquo;ok&raquo;</p>
            <img src="http://127.0.0.1:\(port)/x.png" srcset="http://127.0.0.1:\(port)/y.png 2x"><!-- a comment -->
            <ul><li>one</li><li>two</li></ul><ol start="3"><li>three</li><li>four</li></ol>
            <table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>
            <pre>  keep   spaces
            here</pre><iframe src="http://127.0.0.1:\(port)/f.html"></iframe><video src="http://127.0.0.1:\(port)/v.mp4"></video></body></html>
            """
        pb.clearContents(); pb.setData(Data(page.utf8), forType: .html)
        guard case .text(let got) = Paste.content(of: pb) else { check(false, "html"); return }
        let archive = try! PropertyListSerialization.data(fromPropertyList: ["WebMainResource": ["WebResourceData": Data(page.utf8),
            "WebResourceURL": "http://127.0.0.1:\(port)/", "WebResourceMIMEType": "text/html"]], format: .binary, options: 0)
        pb.clearContents(); pb.setData(archive, forType: NSPasteboard.PasteboardType("com.apple.webarchive"))
        eq(Paste.content(of: pb), .text(got), "a web archive reads as its page")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        eq(hits.n, 0, "no connection made")
        listener.cancel()
        eq(got, "Title & more\nHello web page.\nLine two — «ok»\n• one\n• two\n3. three\n4. four\na\tb\nc\td\n  keep   spaces\nhere")
        // Something with no text form at all.
        pb.clearContents(); pb.setData(Data([0xFF, 0x00, 0xFE]), forType: NSPasteboard.PasteboardType("com.example.binary"))
        eq(Paste.content(of: pb), nil)
    }
}

// MARK: Facts and a paste that waits

/// The counter as it stood in mac/facts.swift before it moved here, to prove the shared one counts the same.
func oldFacts(_ s: String) -> (Int, Int, Int) {
    var chars = 0, words = 0, inWord = false
    for ch in s {
        chars += 1
        let w = ch.isLetter || ch.isNumber
        if w && !inWord { words += 1 }
        inWord = w || (inWord && (ch == "-" || ch == "'" || ch == "’"))
    }
    var cyr = 0, other = 0
    for u in s.unicodeScalars { if (0x0400...0x04FF).contains(u.value) { cyr += 1 } else { other += 1 } }
    return (chars, words, Facts.roundUp(Double(cyr) / 2.8 + Double(other) / 4))
}

@MainActor func testFacts() async {
    await agroup("Facts: same counts as before, lines, off the main thread, cancellable") {
        let f = Facts("Hello, world! It's a well-known fact: 42.")
        eq(f.characters, 41); eq(f.words, 7)
        eq(Facts("").line, "0 characters · 0 words · ≈\u{00A0}0 tokens")
        eq(Facts("a").lines, ["1 Character", "1 Word", "≈\u{00A0}1 Token"])
        eq(Facts("e\u{301}👍🏽 щ").characters, 4, "what a person sees as one character counts once")
        eq(Facts.roundUp(2416), 2450); eq(Facts.roundUp(19941), 20000)
        var g = SystemRandomNumberGenerator()
        let pool = Array("abc Привет 'ё-’ 12 😀👍🏽\n\te\u{301}")
        for _ in 0..<500 {
            let s = String((0..<Int.random(in: 0...80, using: &g)).map { _ in pool.randomElement(using: &g)! })
            let a = Facts(s), b = oldFacts(s)
            check(a.characters == b.0 && a.words == b.1 && a.tokens == b.2, s.debugDescription)
        }
        let big = try! String(contentsOf: benchDir.appendingPathComponent("ten-million.txt"), encoding: .utf8) as NSString
        var t = Date()
        let facts = await Facts.of(big)
        print("    10 M characters counted off the main thread in \(ms(t)): \(facts?.line ?? "nil")")
        let o = oldFacts(big as String)
        eq(facts.map { [$0.characters, $0.words, $0.tokens] }, [o.0, o.1, o.2])
        t = Date()
        let task = Task { await Facts.of(big) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let cancelled = await task.value
        eq(cancelled, nil, "a newer count was asked for: given up"); print("    cancelled after \(ms(t))")
    }

    await agroup("A paste that waits for Vision: its place, its note, one undo step") {
        let lib = Library(); let um = lib.history.undoManager
        let a = lib.newNote(); endEvent()
        let b = lib.newNote(); endEvent()
        edit(lib, b, NSRange(location: 0, length: 0), "hello world"); endEvent()
        lib.history.breakTyping()
        let p = lib.beginPaste(in: b, replacing: NSRange(location: 5, length: 0))
        edit(lib, b, NSRange(location: 0, length: 0), "AB"); endEvent()          // typed before its place
        lib.history.breakTyping()
        edit(lib, b, NSRange(location: 7, length: 0), "X"); endEvent()           // typed at its place, after it in time
        lib.history.breakTyping()
        edit(lib, b, NSRange(location: b.length, length: 0), "!"); endEvent()   // typed after it
        eq(b.text, "ABhelloX world!")
        let r = lib.finishPaste(p, with: "[OCR]")
        eq(b.text, "ABhello[OCR]X world!"); eq(r, NSRange(location: 7, length: 5))
        eq(um.undoActionName, "Paste")
        um.undo(); eq(b.text, "ABhelloX world!", "one step")
        um.redo(); eq(b.text, "ABhello[OCR]X world!")
        // Over a selection: replaced if untouched, kept if edited meanwhile.
        let q = lib.beginPaste(in: b, replacing: NSRange(location: 0, length: 2))
        lib.finishPaste(q, with: "ab"); eq(b.text, "abhello[OCR]X world!")
        let q2 = lib.beginPaste(in: b, replacing: NSRange(location: 0, length: 2))
        lib.history.breakTyping()
        edit(lib, b, NSRange(location: 1, length: 0), "Z"); endEvent()
        lib.finishPaste(q2, with: "P"); eq(b.text, "PaZbhello[OCR]X world!", "edited selection: nothing removed")
        // The empty note it goes into is not dropped while it waits.
        let p2 = lib.beginPaste(in: a, replacing: NSRange(location: 0, length: 0))
        lib.lastOpen = b.id
        lib.leave(a); check(lib.contains(a), "kept while the paste waits")
        lib.finishPaste(p2, with: "late text"); eq(a.text, "late text")
        // A picture with no text: nothing goes in, and the spared empty note goes as it would have.
        let c = lib.newNote(); endEvent()
        let p3 = lib.beginPaste(in: c, replacing: NSRange(location: 0, length: 0))
        lib.leave(c); check(lib.contains(c))
        eq(lib.finishPaste(p3, with: ""), nil); check(!lib.contains(c), "then dropped")
        // Deleted meanwhile: the text goes in anyway, and undoing the delete brings both back.
        let p4 = lib.beginPaste(in: a, replacing: NSRange(location: 0, length: 0))
        lib.delete([a]); endEvent()
        lib.finishPaste(p4, with: ">> ")
        um.undo(); check(lib.contains(a)); eq(a.text, ">> late text")
        // The real thing: a screenshot read by Vision while the person types on.
        let text = "Pasted while typing"
        let task = Task { await lib.paste(.image(card(text)), into: b, replacing: NSRange(location: 0, length: 0)) }
        lib.history.breakTyping()
        for _ in 0..<5 { await Task.yield(); edit(lib, b, NSRange(location: 0, length: 0), "t"); endEvent() }
        let range = await task.value
        check(b.text.hasPrefix(text + "ttttt"), "typed during the read, after the paste in time: \(b.text.prefix(40))")
        um.undo(); check(b.text.hasPrefix("ttttt"), "the paste undone in one step")
        check(range != nil)
    }
}

// MARK: speed

@MainActor func bench() {
    print("bench (\(ProcessInfo.processInfo.processorCount) cores)")
    print(String(format: "  memory at start: %.0f MB", footprintMB()))
    for name in ["war-and-peace", "ten-million"] {
        let data = try! Data(contentsOf: benchDir.appendingPathComponent("\(name).txt"))
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        let id = UUID()
        try! data.write(to: dir.appendingPathComponent("Notes/\(id.uuidString).txt"))
        let m0 = footprintMB()
        var t = Date()
        let lib = Library(store: Store(dir: dir))
        let loadTime = ms(t)
        let n = lib.note(id: id)!
        let m1 = footprintMB()
        print("  \(name): \(n.length) UTF-16 units, \(data.count) bytes")
        print("    load (read, decode, storage): \(loadTime); memory +\(Int(m1 - m0)) MB")
        t = Date(); _ = n.textSnapshot; print("    snapshot on the main thread: \(ms(t))")
        edit(lib, n, NSRange(location: n.length / 2, length: 0), "x")
        t = Date(); lib.flush(); print("    save (snapshot + UTF-8 + atomic write): \(ms(t))")
        // Typing in the middle of the big text through the history.
        var times: [Double] = []
        for i in 0..<200 {
            let s = Date(); edit(lib, n, NSRange(location: n.length / 2 + i, length: 0), "y"); times.append(Date().timeIntervalSince(s) * 1000)
        }
        endEvent()
        times.sort()
        print(String(format: "    keystroke through History + storage, median %.3f ms, max %.3f ms", times[100], times.last!))
        lib.history.breakTyping()
        t = Date(); edit(lib, n, NSRange(location: 0, length: n.length), "", .cut); endEvent(); print("    ⌘A ⌘X recorded: \(ms(t))")
        t = Date(); lib.history.undoManager.undo(); print("    undo of that: \(ms(t))")
        t = Date(); lib.history.undoManager.redo(); lib.history.undoManager.undo(); print("    redo + undo: \(ms(t))")
        let base = n.textSnapshot
        let mid = base.length / 2
        let local = base.replacingCharacters(in: NSRange(location: base.length / 10, length: 5), with: "LOCAL") as NSString
        let remote = base.replacingCharacters(in: NSRange(location: base.length * 9 / 10, length: 5), with: "REMOTE") as NSString
        t = Date(); _ = Diff.minimalReplacement(from: base, to: local); print("    minimal replacement: \(ms(t))")
        t = Date(); let merged = Merge.threeWay(base: base, local: local, remote: remote); print("    three-way merge, edits far apart: \(ms(t))")
        check(merged.range(of: "LOCAL").location != NSNotFound && merged.range(of: "REMOTE").location != NSNotFound)
        let l2 = base.replacingCharacters(in: NSRange(location: mid, length: 3), with: "L") as NSString
        let r2 = base.replacingCharacters(in: NSRange(location: mid + 1, length: 3), with: "R") as NSString
        t = Date(); let m2 = Merge.threeWay(base: base, local: l2, remote: r2); print("    three-way merge, edits overlapping in one line: \(ms(t))")
        check(m2.range(of: "L").location != NSNotFound)
        // A big rewrite on both sides: a thousand lines changed differently in the middle.
        let lines = (base as String).components(separatedBy: "\n")
        var lw = lines, rw = lines
        let start = lines.count / 2 - 500
        for i in start..<(start + 1000) where i % 2 == 0 { lw[i] = "L" + lw[i] }
        for i in start..<(start + 1000) where i % 3 == 0 { rw[i] = rw[i] + "R" }
        t = Date(); let m3 = Merge.threeWay(base: base, local: lw.joined(separator: "\n") as NSString, remote: rw.joined(separator: "\n") as NSString)
        print("    three-way merge, 1000 lines rewritten on both sides: \(ms(t)), \(m3.length) units")
        t = Date(); _ = lib.applyRemote(n, text: remote, modified: nil); print("    apply a remote change (diff + replace): \(ms(t))")
        print(String(format: "    memory now: %.0f MB", footprintMB()))
    }
    benchWholeLibrary()
}

/// ⌘A ⌘⌫ of every note, then ⌘Z and ⇧⌘Z: what the core spends on the main thread, with a store and sync attached.
@MainActor func benchWholeLibrary() {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let big = try! String(contentsOf: benchDir.appendingPathComponent("ten-million.txt"), encoding: .utf8)
    let store = Store(dir: dir)
    let lib = Library(store: store)
    let sync = Sync(library: lib, database: FakeDevice(FakeServer()))
    sync.autorun = false; sync.anyFolder = true; sync.start()
    for i in 0..<100 { let n = lib.newNote(); n.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: i == 0 ? big : "note \(i) " + String(repeating: "text ", count: 200)) }
    endEvent(); lib.flush()
    var lists = 0
    let o = NotificationCenter.default.addObserver(forName: Library.didChange, object: lib, queue: nil) { _ in lists += 1 }
    defer { NotificationCenter.default.removeObserver(o) }
    print("  whole library, 100 notes (one of 10 M characters), store and sync attached:")
    var t = Date(); lists = 0
    lib.delete(lib.notes); endEvent()
    print("    ⌘A ⌘⌫: \(ms(t)) on the main thread, \(lists) change notifications")
    t = Date(); lib.flush(); print("    its write (flush, waits for the disk): \(ms(t))")
    t = Date(); lists = 0
    lib.history.undoManager.undo()
    print("    ⌘Z: \(ms(t)) on the main thread, \(lists) change notifications, \(lib.notes.count) notes back")
    t = Date(); lib.flush(); print("    its write: \(ms(t))")
    t = Date(); lists = 0
    lib.history.undoManager.redo()
    print("    ⇧⌘Z: \(ms(t)), \(lists) change notifications")
    t = Date(); lib.history.undoManager.undo(); print("    ⌘Z again: \(ms(t))")
    lib.flush()
}

// MARK: paragraph direction

/// Direction (shared/direction.swift): UBA P2/P3 per paragraph, and fix keeping it through edits as both editors call it.
@MainActor func testDirection() {
    func dirs(_ s: String) -> [Bool] {
        var out: [Bool] = []
        let ns = s as NSString
        Direction.paragraphs(ns, NSRange(location: 0, length: ns.length)) { _, rtl in out.append(rtl) }
        return out
    }
    func styled(_ st: NSTextStorage) -> [Int] {
        // Each paragraph's direction as set: 1 right to left, 0 left to right, -1 none or mixed inside it.
        var out: [Int] = []
        let ns = st.mutableString
        var at = 0
        while at < ns.length {
            let p = ns.paragraphRange(for: NSRange(location: at, length: 0))
            var eff = NSRange()
            let ps = st.attribute(.paragraphStyle, at: p.location, longestEffectiveRange: &eff, in: p) as? NSParagraphStyle
            out.append(NSMaxRange(eff) < NSMaxRange(p) || ps == nil ? -1 : ps!.baseWritingDirection == .rightToLeft ? 1 : 0)
            at = NSMaxRange(p)
        }
        return out
    }
    group("Direction: UBA P2/P3 per paragraph") {
        eq(dirs("Hello"), [false])
        eq(dirs("שלום עולם"), [true], "Hebrew")
        eq(dirs("مرحبا بالعالم"), [true], "Arabic")
        eq(dirs("123, «مرحبا» and more"), [true], "neutrals before the first strong letter")
        eq(dirs("Привет مرحبا"), [false], "Cyrillic first")
        eq(dirs("مرحبا Hello"), [true], "Arabic first")
        eq(dirs("   ...  "), [false], "no strong letter: left to right")
        eq(dirs("\u{2068}مرحبا\u{2069} Hello"), [false], "an isolate skipped (FSI…PDI)")
        eq(dirs("\u{2067}abc\u{2069}שלום"), [true], "an isolate skipped (RLI…PDI)")
        eq(dirs("a\nש\r\nb\rم\u{2029}x"), [false, true, false, true, false], "LF, CR LF, CR, U+2029")
        eq(dirs("ש\n"), [true], "a break ends the paragraph; nothing after it is another")
        eq(dirs("😀𞤀"), [true], "Adlam past the BMP (a surrogate pair) is right to left")
        eq(dirs("😀𝐀"), [false], "a mathematical bold A past the BMP is left to right")
        // Chunk edges (16,384 units): a surrogate pair and a CR LF split by one.
        let pad = String(repeating: " ", count: 16_383)
        eq(dirs(pad + "𞤀"), [true], "surrogate pair across the chunk's end")
        eq(dirs(pad + "\r\nש"), [false, true], "CR LF across the chunk's end")
        eq(dirs(String(repeating: "x\n", count: 20_000) + "ש").count, 20_001)
    }
    group("Direction: fix keeps each paragraph's direction through edits") {
        let st = NSTextStorage(string: "Hello\nשלום\nمرحبا Hi\n")
        Direction.fix(st, around: NSRange(location: 0, length: st.length))
        eq(styled(st), [0, 1, 1])
        // Typing at a paragraph's start, as an editor does: the characters come without a style, fix gives them one.
        @MainActor func type(_ s: String, at i: Int) {
            st.replaceCharacters(in: NSRange(location: i, length: 0), with: s)
            Direction.fix(st, around: NSRange(location: i, length: (s as NSString).length))
        }
        @MainActor func delete(_ r: NSRange) {
            st.replaceCharacters(in: r, with: "")
            Direction.fix(st, around: NSRange(location: r.location, length: 0))
        }
        type("ש", at: 0); eq(styled(st), [1, 1, 1], "a Hebrew letter first turns the paragraph")
        delete(NSRange(location: 0, length: 1)); eq(styled(st), [0, 1, 1], "and its deletion turns it back")
        type("x", at: 3); eq(styled(st), [0, 1, 1], "typing inside keeps it")
        let afterHello = ("Helxlo" as NSString).length
        delete(NSRange(location: afterHello, length: 1)); eq(styled(st), [0, 1], "two paragraphs joined take the first's")
        type("\n", at: afterHello); eq(styled(st), [0, 1, 1], "Return splits; the new paragraph is its own")
        type("abc\nمرحبا\n", at: 0); eq(styled(st), [0, 1, 0, 1, 1], "a paste of several paragraphs")
        st.replaceCharacters(in: NSRange(location: 0, length: st.length), with: "")
        Direction.fix(st, around: NSRange(location: 0, length: 0)); eq(st.length, 0, "empty text: nothing to do")
    }
}

// MARK: run

@MainActor func main() async {
    if CommandLine.arguments.dropFirst().first == "bench" {
        bench()
    } else if CommandLine.arguments.dropFirst().first == "stormone" {
        let a = CommandLine.arguments
        testUndoStorm(seeds: UInt64(a[2])!..<(UInt64(a[2])! + 1), steps: Int(a[3])!)
    } else if CommandLine.arguments.dropFirst().first == "storm" {
        testUndoStorm(seeds: 0..<400, steps: 4000)
    } else {
        testOrdinal()
        testDirection()
        testMerge()
        testLibrary()
        testPinned()
        testSettings()
        testHistory()
        testUndoStorm(seeds: 0..<24, steps: 2500)
        testStore()
        await testSync()
        await testPaste()
        await testFacts()
    }
    print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
    exit(failures == 0 ? 0 : 1)
}
await main()
