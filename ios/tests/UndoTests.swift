// The text view keeps no undo of its own: everything it registers is dropped, and undo through it is the History's.
import UIKit
import XCTest
@testable import Merum

@MainActor final class UndoTests: XCTestCase {
    private func window() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first!
    }

    /// A library in memory with one note made outside the history (so the only steps are the test's own), shown in a
    /// text view in the app's window with the keyboard up.
    private func setUp(_ text: String = "") -> (Library, Model, Note, NoteTextView) {
        let lib = Library()
        let note = Note(title: "Test", position: 1, storage: NSTextStorage(string: text))
        lib.restore([note])
        let model = Model(library: lib)
        model.show(note)
        let tv = model.editors.view(for: note)
        tv.frame = window().bounds
        window().addSubview(tv)
        XCTAssertTrue(tv.becomeFirstResponder())
        return (lib, model, note, tv)
    }

    /// A key as the keyboard sends it: UIKit asks the delegate first (it does not for insertText called from code).
    private func key(_ tv: UITextView, _ text: String) {
        if tv.delegate?.textView?(tv, shouldChangeTextIn: tv.selectedRange, replacementText: text) ?? true { tv.insertText(text) }
        tick()
    }
    private func backspace(_ tv: UITextView) {
        let r = tv.selectedRange
        let range = r.length > 0 ? r : NSRange(location: max(0, r.location - 1), length: r.location > 0 ? 1 : 0)
        if tv.delegate?.textView?(tv, shouldChangeTextIn: range, replacementText: "") ?? true { tv.deleteBackward() }
        tick()
    }

    /// One turn of the run loop: each tap or key is its own event, and the undo manager groups by event.
    private func tick() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func tearDown(_ tv: UITextView) {
        tv.resignFirstResponder()
        tv.removeFromSuperview()
    }

    func testTypingRegistersNothingInTheTextViewAndUndoesThroughHistory() {
        let (lib, _, note, tv) = setUp()
        defer { tearDown(tv) }
        key(tv, "Milk")
        key(tv, ", bread")
        XCTAssertEqual(note.storage.string, "Milk, bread")
        // UIKit asked the text view's manager to register; nothing was kept there.
        let proxy = tv.undoManager as! ForwardingUndoManager
        XCTAssertFalse(proxy.isUndoRegistrationEnabled)
        // The History holds one coalesced typing step, under Apple's name, and nothing of UIKit's.
        let um = lib.history.undoManager
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(um.undoActionName, "Typing")
        XCTAssertEqual(proxy.undoMenuItemTitle, "Undo Typing")
        // Undo through the text view's manager, as shake, three fingers and ⌘Z do.
        proxy.undo()
        XCTAssertEqual(note.storage.string, "")
        XCTAssertFalse(um.canUndo, "a step of UIKit's own was left in the History")
        XCTAssertTrue(proxy.canRedo)
        proxy.redo()
        XCTAssertEqual(note.storage.string, "Milk, bread")
    }

    func testDeleteBackwardAndPasteAreOneStepEach() {
        let (lib, model, note, tv) = setUp("Gate code 4417")
        defer { tearDown(tv) }
        tv.selectedRange = NSRange(location: 14, length: 0)
        tick()
        backspace(tv)
        backspace(tv)
        XCTAssertEqual(note.storage.string, "Gate code 44")
        model.editors.replace(tv.selectedRange, with: "18", in: tv, kind: .paste)
        XCTAssertEqual(note.storage.string, "Gate code 4418")
        tick()
        let um = lib.history.undoManager
        XCTAssertEqual(um.undoActionName, "Paste")
        tv.undoManager?.undo(); tick()
        XCTAssertEqual(note.storage.string, "Gate code 44")
        XCTAssertEqual(um.undoActionName, "Typing")
        tv.undoManager?.undo()
        XCTAssertEqual(note.storage.string, "Gate code 4417")
        XCTAssertFalse(um.canUndo)
    }

    func testDeletingANoteIsUndoneThroughTheWindowsManager() {
        let lib = Library()
        let a = lib.newNote(), b = lib.newNote()
        a.storage.mutableString.setString("Gate code 4417")   // empty notes go when left (Library.leave)
        b.storage.mutableString.setString("Milk")
        let model = Model(library: lib)
        tick()
        model.delete([a.id])
        tick()
        XCTAssertFalse(lib.contains(a))
        let w = HistoryWindow(frame: .zero)
        w.proxy.history = lib.history.undoManager
        XCTAssertEqual(w.undoManager?.undoMenuItemTitle, "Undo Delete Note")
        w.undoManager?.undo()
        XCTAssertTrue(lib.contains(a))
        XCTAssertTrue(lib.contains(b))
    }

    func testPastedTextTakesTheNotesFont() {
        let (_, model, note, tv) = setUp()
        defer { tearDown(tv) }
        model.editors.replace(NSRange(location: 0, length: 0), with: "Plain", in: tv, kind: .paste)
        let f = note.storage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(f, model.editors.font)
    }

    /// The list's onMove gives offsets in the shown order; the note lands where it was dropped, one «Move Note» step.
    func testReorderIsOneMoveNoteStep() {
        let lib = Library()
        let a = lib.newNote(), b = lib.newNote(), c = lib.newNote()
        for (n, t) in [(a, "a"), (b, "b"), (c, "c")] { n.storage.mutableString.setString(t) }
        let model = Model(library: lib)
        tick()
        model.move(pinned: false, from: IndexSet(integer: 0), to: 3)   // the first row dropped below the last
        tick()
        XCTAssertEqual(lib.notes.map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(lib.history.undoManager.undoActionName, "Move Note")
        lib.history.undoManager.undo()
        XCTAssertEqual(lib.notes.map(\.id), [a.id, b.id, c.id])
    }

    /// Pinning from the list or the editor: one step under the core's name, the note first in the list, undone.
    func testPinIsOneStepAndPinnedComeFirst() {
        let lib = Library()
        let a = lib.newNote(), b = lib.newNote()
        a.storage.mutableString.setString("a"); b.storage.mutableString.setString("b")
        let model = Model(library: lib)
        tick()
        model.togglePin([b.id])
        tick()
        XCTAssertEqual(lib.notes.first?.id, b.id)
        XCTAssertTrue(model.rows.first?.pinned ?? false)
        XCTAssertEqual(lib.history.undoManager.undoActionName, "Pin Note")
        XCTAssertTrue(model.allPinned([b.id]))
        model.togglePin([a.id, b.id])   // not all pinned: pins both
        tick()
        XCTAssertEqual(lib.history.undoManager.undoActionName, "Pin Note")   // only a changed
        lib.history.undoManager.undo(); tick()
        lib.history.undoManager.undo(); tick()
        XCTAssertFalse(a.pinned || b.pinned)
    }
}
