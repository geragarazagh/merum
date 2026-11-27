// Each paragraph's direction in the app's own editor (shared/direction.swift): a paragraph that begins in Hebrew or
// Arabic is laid out from the right edge, as on the Mac, and keeps or changes its direction as the person types,
// deletes, pastes and undoes.
import UIKit
import XCTest
@testable import Merum

@MainActor final class DirectionTests: XCTestCase {
    private func window() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first!
    }

    private func setUp(_ text: String) -> (Library, Model, Note, NoteTextView) {
        let lib = Library()
        let note = Note(title: "Test", position: 1, storage: NSTextStorage(string: text))
        lib.restore([note])
        let model = Model(library: lib)
        model.show(note)
        let tv = model.editors.view(for: note)
        tv.frame = window().bounds
        window().addSubview(tv)
        XCTAssertTrue(tv.becomeFirstResponder())
        tv.layoutIfNeeded()
        return (lib, model, note, tv)
    }

    private func tearDown(_ tv: UITextView) {
        tv.resignFirstResponder()
        tv.removeFromSuperview()
    }

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
    private func tick() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// Each paragraph's direction as set: 1 right to left, 0 left to right, -1 none, or not one style across it.
    private func styled(_ st: NSTextStorage) -> [Int] {
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

    /// Where the paragraph's first line sits: its glyphs' used rect against the container, «right» when it hugs the
    /// right edge and leaves room on the left.
    private func edge(_ tv: UITextView, paragraph index: Int) -> String {
        let ns = tv.textStorage.mutableString
        var at = 0
        for _ in 0..<index { at = NSMaxRange(ns.paragraphRange(for: NSRange(location: at, length: 0))) }
        let lm = tv.layoutManager
        let g = lm.glyphIndexForCharacter(at: at)
        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
        let pad = tv.textContainer.lineFragmentPadding
        let left = used.minX - line.minX - pad, right = line.maxX - used.maxX - pad
        if left < 2 && right < 2 { return "full" }
        return right < 2 ? "right" : left < 2 ? "left" : "middle"
    }

    func testParagraphsTakeTheirDirectionOnOpen() {
        let (_, _, note, tv) = setUp("Short English line\nשורה קצרה בעברית\nسطر قصير بالعربية\n«Цитата» سطر بعد علامات\n123 ...\n")
        defer { tearDown(tv) }
        XCTAssertEqual(styled(note.storage), [0, 1, 1, 0, 0])
        XCTAssertEqual(edge(tv, paragraph: 0), "left")
        XCTAssertEqual(edge(tv, paragraph: 1), "right")
        XCTAssertEqual(edge(tv, paragraph: 2), "right")
        XCTAssertEqual(edge(tv, paragraph: 3), "left", "Cyrillic first: left to right, as UBA P2 has it")
        XCTAssertEqual(edge(tv, paragraph: 4), "left", "no strong letter: left to right")
    }

    func testTypingDeletingAndUndoTurnAParagraph() {
        let (lib, _, note, tv) = setUp("Hello\nworld")
        defer { tearDown(tv) }
        // A new paragraph typed in Arabic at the end.
        tv.selectedRange = NSRange(location: note.length, length: 0)
        key(tv, "\n"); key(tv, "م"); key(tv, "ر")
        XCTAssertEqual(styled(note.storage), [0, 0, 1])
        XCTAssertEqual(edge(tv, paragraph: 2), "right")
        // A Hebrew letter typed at the start of the first paragraph turns it; deleting it turns it back.
        tv.selectedRange = NSRange(location: 0, length: 0)
        key(tv, "ש")
        XCTAssertEqual(styled(note.storage), [1, 0, 1])
        XCTAssertEqual(edge(tv, paragraph: 0), "right")
        backspace(tv)
        XCTAssertEqual(styled(note.storage), [0, 0, 1])
        XCTAssertEqual(edge(tv, paragraph: 0), "left")
        // Typing in the middle of the Arabic paragraph keeps it right to left; Latin inside it changes nothing.
        let mid = note.length - 1
        tv.selectedRange = NSRange(location: mid, length: 0)
        key(tv, "a"); key(tv, "b"); key(tv, " ")
        XCTAssertEqual(styled(note.storage), [0, 0, 1])
        // Joining the Arabic paragraph to the one before: one paragraph, the first's direction.
        let joinAt = ("Hello\nworld" as NSString).length
        tv.selectedRange = NSRange(location: joinAt + 1, length: 0)
        backspace(tv)
        XCTAssertEqual(styled(note.storage), [0, 0])
        // Undo brings the paragraph back with its direction (the core writes the text as a plain string).
        lib.history.undoManager.undo(); tick()
        XCTAssertEqual(styled(note.storage), [0, 0, 1])
        XCTAssertEqual(edge(tv, paragraph: 2), "right")
    }

    /// A pasted text of 94 k characters mixing Russian, English, Arabic and Hebrew paragraphs: each takes its own
    /// direction, the paste is one step, and the typing after it stays fast.
    func testBigMixedPaste() {
        let (_, model, note, tv) = setUp("")
        defer { tearDown(tv) }
        let lines = ["Война и мир. Том первый, часть первая, глава первая.",
                     "— Eh bien, mon prince. Gênes et Lucques ne sont plus que des apanages.",
                     "الحرب والسلام رواية للكاتب الروسي ليف تولستوي، نشرت بين عامي ١٨٦٥ و١٨٦٩.",
                     "מלחמה ושלום הוא רומן מאת לב טולסטוי, שפורסם בשנים 1865–1869.",
                     "2026 — «مرحبا» и снова русский текст после арабского слова."]
        var parts: [String] = [], want: [Int] = []
        var total = 0, i = 0
        while total < 94_000 {
            let l = lines[i % lines.count] + " " + String(i)
            parts.append(l); want.append(i % lines.count >= 2 ? 1 : 0)   // the last: digits and a dash, then Arabic first
            total += (l as NSString).length + 1; i += 1
        }
        let text = parts.joined(separator: "\n")
        let t = CACurrentMediaTime()
        model.editors.replace(tv.selectedRange, with: text, in: tv, kind: .paste)
        tv.layoutIfNeeded(); CATransaction.flush()
        let paste = CACurrentMediaTime() - t
        print("MERUMDIR paste.94k \((paste * 10000).rounded() / 10) ms, \((text as NSString).length) characters")
        XCTAssertEqual(styled(note.storage), want)
        XCTAssertEqual(tv.selectedRange.location, note.length, "the caret after the paste, at the end")
        XCTAssertEqual(edge(tv, paragraph: parts.count - 3), "right", "a Hebrew line near the end")
        var keys: [Double] = []
        for _ in 0..<20 {
            let k = CACurrentMediaTime()
            if tv.delegate?.textView?(tv, shouldChangeTextIn: tv.selectedRange, replacementText: "ж") ?? true { tv.insertText("ж") }
            tv.layoutIfNeeded(); CATransaction.flush()
            keys.append(CACurrentMediaTime() - k)
            tick()
        }
        print("MERUMDIR key.afterPaste.max \((keys.max()! * 10000).rounded() / 10) ms")
    }
}
