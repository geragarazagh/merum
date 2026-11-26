// Simulator-only, Debug-only modes (nothing of this exists in a device build):
//   -merumMonkey <seconds>   random fast operations through the real model and editor: compose, typing, select all +
//                            delete, undo and redo bursts, a whole-book paste, back and forward, sort changes while
//                            editing, pins, deletes. Every step checks that the library and the screen agree; the tally
//                            goes to tmp/monkey.txt.
//   -merumShots              the notes of the App Store pictures: a book, a picture read as text, everyday notes.
// Both work on the simulator's own store, which they empty first.
#if DEBUG && targetEnvironment(simulator)
import UIKit
import Vision

@MainActor enum SimulatorModes {
    /// The launch arguments, a string of several split into words (a runner may pass them as one).
    static var args: [String] { ProcessInfo.processInfo.arguments.flatMap { $0.split(separator: " ").map(String.init) } }

    static func runIfAsked() {
        if let i = args.firstIndex(of: "-merumMonkey") {
            let secs = i + 1 < args.count ? Double(args[i + 1]) ?? 60 : 60
            Task { try? await Task.sleep(for: .seconds(2)); await monkey(seconds: secs) }
        }
        if args.contains("-merumShots") { Task { await shots() } }
    }

    private static var app: Merum { Merum.shared }
    private static var lib: Library { app.library }
    private static var model: Model { app.model }
    private static var log: [String] = []
    private static func say(_ s: String) {
        log.append(s)
        try? log.joined(separator: "\n").appending("\n")
            .write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("monkey.txt"), atomically: true, encoding: .utf8)
    }

    private static func book() -> String {
        let path = args.firstIndex(of: "-merumBook").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? String(repeating: "Война и мир. War and Peace. ", count: 100_000)
        // The file's first line is a download site's header, not the book.
        return text.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? text
    }

    private static func emptyLibrary() {
        lib.delete(lib.notes)
        lib.history.undoManager.removeAllActions()
    }

    private static func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: monkey

    private static func monkey(seconds: Double) async {
        say("start \(Date())")
        emptyLibrary()
        let bookText = book()
        let end = Date().addingTimeInterval(seconds)
        var counts: [String: Int] = [:]
        var problems: [String] = []
        model.compose()
        await pause(400)
        while Date() < end {
            let op = Int.random(in: 0..<100)
            let name: String
            switch op {
            case 0..<14:
                name = "compose"; model.compose()
            case 14..<38:
                name = "type"
                if let tv = model.editors.container.shown {
                    for ch in ["M", "e", "r", "u", "m", " ", "ж", "\n"].shuffled().prefix(Int.random(in: 1...8)) {
                        if model.editors.textView(tv, shouldChangeTextIn: tv.selectedRange, replacementText: ch) { tv.insertText(ch) }
                    }
                }
            case 38..<48:
                name = "selectAllDelete"
                if let tv = model.editors.container.shown, let n = tv.note {
                    model.editors.replace(NSRange(location: 0, length: n.length), with: "", in: tv, kind: .cut)
                }
            case 48..<60 where !args.contains("-noUndo"):
                name = "undoBurst"
                let um = lib.history.undoManager
                for _ in 0..<Int.random(in: 1...6) where um.canUndo { um.undo() }
                if Bool.random() { for _ in 0..<Int.random(in: 1...3) where um.canRedo { um.redo() } }
            case 60..<63:
                name = "hugePaste"
                if let tv = model.editors.container.shown {
                    model.editors.replace(tv.selectedRange, with: bookText, in: tv, kind: .paste)
                }
            case 63..<75:
                name = "backForward"
                model.path = []
                await pause(Int.random(in: 0...250))
                if let r = model.rows.randomElement() { model.open(r.id) } else { model.compose() }
            case 75..<83:
                name = "sortWhileEditing"
                lib.sort = Library.Sort.allCases.randomElement()!
                lib.ascending.toggle()
            case 83..<90:
                name = "pin"
                if let r = model.rows.randomElement() { model.togglePin([r.id]) }
            case 90..<96:
                name = "deleteNote"
                if let r = model.rows.randomElement() { model.delete([r.id]) }
            default:
                name = "textSize/other"
                lib.textSize = Library.textSizes.randomElement()!
            }
            counts[name, default: 0] += 1
            await pause(Int.random(in: 0...40))
            // The screen and the library agree: the shown view belongs to the shown note, which the library holds or
            // which is the draft; every row is a note.
            if let tv = model.editors.container.shown, tv.note !== model.current, model.path == [.editor] {
                // SwiftUI puts the new view up on its next update; only a mismatch that outlives that is a fault.
                await pause(300)
                if let tv2 = model.editors.container.shown, tv2.note !== model.current, model.path == [.editor] {
                    problems.append("view/note mismatch after \(name)")
                }
            }
            if let c = model.open, !lib.contains(c), model.path == [.editor] { problems.append("open note not in library after \(name)") }
            if model.rows.count != lib.notes.count { problems.append("rows \(model.rows.count) vs notes \(lib.notes.count) after \(name)") }
        }
        model.path = []
        await pause(600)
        say("monkey \(Int(seconds)) s: \(counts.values.reduce(0, +)) operations \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        say("notes at the end \(lib.notes.count), problems \(problems.count)")
        for p in Set(problems) { say("problem: \(p)") }
        say("done")
    }

    // MARK: the App Store pictures

    private static func shots() async {
        emptyLibrary()
        lib.sort = .manual
        lib.textSize = 100
        func make(_ text: String, name: String? = nil, pinned: Bool = false) -> Note {
            let n = lib.newNote()
            n.storage.mutableString.setString(text)
            if let name { lib.rename(n, to: name) }
            if pinned { lib.pin([n], true) }
            return n
        }
        let war = make(book(), name: "War and Peace", pinned: true)
        _ = make("Milk\nEggs\nRye bread\nLemons\nCoffee beans\nOlive oil")
        // A picture with no file behind it, read as the paste reads it (Vision, on the device).
        let recognised = await Paste.recognize(recipeImage())
        _ = make(recognised.isEmpty ? "(nothing recognised)" : recognised)
        _ = make("git log --oneline --graph --all\ngit switch -c release\ngit push -u origin release")
        _ = make("Ideas for the weekend:\n– the river walk at seven\n– finish the chapter on Austerlitz\n– fix the bike's back brake")
        lib.history.undoManager.removeAllActions()
        // -shotsOpen N opens the Nth note of the list (0: the book), -shotsSize P sets the text size.
        if let i = args.firstIndex(of: "-shotsSize"), i + 1 < args.count, let v = Int(args[i + 1]) { lib.textSize = v }
        var target = war
        if args.contains("-shotsEmpty") { target = lib.newNote() }
        if let i = args.firstIndex(of: "-shotsOpen"), i + 1 < args.count, let k = Int(args[i + 1]), k < lib.notes.count { target = lib.notes[k] }
        model.path = []
        model.show(target)
        model.path = [.editor]
        say("shots ready")
    }

    /// A screenshot-like picture of a recipe, drawn here, for the paste-a-picture note.
    private static func recipeImage() -> CGImage {
        let size = CGSize(width: 1179, height: 900)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: UIColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.darkGray]
            ("Buckwheat Pancakes" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: title)
            let lines = ["200 g buckwheat flour", "2 eggs", "300 ml milk", "1 tsp baking powder", "A pinch of salt",
                         "Rest the batter for 20 minutes,", "then fry on a hot pan."]
            for (i, l) in lines.enumerated() { (l as NSString).draw(at: CGPoint(x: 60, y: 190 + i * 90), withAttributes: body) }
        }
        return img.cgImage!
    }
}
#endif
