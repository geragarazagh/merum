// A launch (the icon, Apple's Open App action, Spotlight) lands on the note open last, keyboard up, caret at the end;
// with no note open before, on a fresh draft, keyboard up. Each test is a cold launch as iOS makes it: a library read
// from disk, its Model, and the scene's window with RootView, built beside the test host's own.
import SwiftUI
import UIKit
import XCTest
@testable import Merum

@MainActor final class LaunchTests: XCTestCase {
    private var dir: URL!
    private var window: UIWindow?

    private func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    private func waitFor(_ s: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(s)
        while Date() < end { if ok() { return true }; wait(0.01) }
        return ok()
    }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        close()
        try? FileManager.default.removeItem(at: dir)
    }

    /// The launched window goes, with nothing of it left to take the keyboard; the test host's window is key again.
    private func close() {
        guard let w = window else { return }
        w.endEditing(true)
        w.isHidden = true
        w.rootViewController = nil
        w.windowScene = nil
        window = nil
        Merum.shared.model.editors.container.window?.makeKey()
        wait(0.5)
    }

    /// Notes written to disk as an earlier run left them; `last` is the index of the note open last (nil: none).
    private func previousRun(notes: Int, last: Int?) -> [UUID] {
        let lib = Library(store: Store(dir: dir))
        var ids: [UUID] = []
        for k in 0..<notes {
            let n = lib.newNote()
            n.storage.mutableString.setString("Launch test \(k)\n" + String(repeating: "line of text \(k)\n", count: 60 * (k + 1)))
            ids.append(n.id)
        }
        lib.lastOpen = last.map { ids[$0] }
        lib.flush()
        return ids
    }

    /// What SceneDelegate does on a cold launch, over this test's library.
    private func launch() -> Model {
        let lib = Library(store: Store(dir: dir))
        let model = Model(library: lib)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let w = HistoryWindow(windowScene: scene)
        w.proxy.history = lib.history.undoManager
        w.rootViewController = UIHostingController(rootView: RootView().environment(model))
        w.makeKeyAndVisible()
        window = w
        return model
    }

    private func checkTyping(_ model: Model, at id: UUID?, _ tag: String) {
        func endInView(_ tv: UITextView) -> Bool {
            let caret = tv.caretRect(for: tv.endOfDocument)
            let visible = tv.bounds.inset(by: tv.adjustedContentInset)
            return caret.minY >= visible.minY - 1 && caret.maxY <= visible.maxY + 1
        }
        let ok = waitFor(3.0) {
            guard let tv = model.editors.container.shown else { return false }
            return tv.isFirstResponder && (id == nil || tv.note?.id == id) && endInView(tv)
        }
        let tv = model.editors.container.shown
        XCTAssertTrue(ok, "not typing at the end of the expected note: \(tag) (path \(model.path.count), shown \(tv?.note?.id.uuidString ?? "none"), first responder \(tv?.isFirstResponder ?? false), end in view \(tv.map(endInView) ?? false))")
        guard let tv, let note = tv.note else { return }
        XCTAssertEqual(model.path.count, 1, "not on the editor: \(tag)")
        XCTAssertEqual(tv.selectedRange, NSRange(location: note.storage.length, length: 0), "caret not at the end: \(tag)")
    }

    func testOpensTheLastNote() {
        let ids = previousRun(notes: 3, last: 1)
        let model = launch()
        checkTyping(model, at: ids[1], "last note")
        XCTAssertEqual(model.current?.id, ids[1])
    }

    func testOpensADraftWithNoNoteBefore() {
        _ = previousRun(notes: 0, last: nil)
        let model = launch()
        checkTyping(model, at: nil, "draft")
        XCTAssertEqual(model.current?.length, 0)
    }

    /// Launch, then Back and a row at every pace: the row's note opens, keyboard up, caret at the end.
    func testLaunchBackOpen() {
        let ids = previousRun(notes: 3, last: 0)
        for ms in stride(from: 100, through: 900, by: 200) {
            let model = launch()
            checkTyping(model, at: ids[0], "launch \(ms)")
            wait(Double(ms) / 1000)
            model.path = []
            wait(Double(ms) / 1000)
            let n = ids[ms / 200 % 2 + 1]
            model.open(n)
            checkTyping(model, at: n, "launch, \(ms) ms, back, open")
            model.library.lastOpen = ids[0]
            model.library.flush()
            close()
        }
    }
}
