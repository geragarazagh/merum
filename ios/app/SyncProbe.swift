// Debug builds only, and only when launched with -merumSyncProbe: drives the joint sync test from the Mac. Commands
// arrive as lines in tmp/probe-in.txt (devicectl copy to); results, each with the phone's clock in ms, go to
// tmp/probe-out.txt. It touches only notes whose names start with «zz-test-»: every command names a tag, the name is
// built here, and anything else in the library is never edited, moved or deleted.
#if DEBUG && MERUM_ICLOUD
import UIKit

@MainActor enum SyncProbe {
    static let prefix = "zz-test-"
    private static var done = 0
    private static var lines: [String] = []
    private static let dir = URL(fileURLWithPath: NSTemporaryDirectory())

    static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-merumSyncProbe") else { return }
        try? "".write(to: dir.appendingPathComponent("probe-in.txt"), atomically: true, encoding: .utf8)
        say("ready")
        Task { await loop() }
    }

    private static func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
    private static func say(_ s: String) {
        lines.append("\(now()) \(s)")
        try? lines.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("probe-out.txt"),
                                                                atomically: true, encoding: .utf8)
    }

    private static var lib: Library { Merum.shared.library }
    private static func note(_ tag: String) -> Note? { lib.notes.first { $0.title == prefix + tag } }

    private static func loop() async {
        while true {
            let all = ((try? String(contentsOf: dir.appendingPathComponent("probe-in.txt"), encoding: .utf8)) ?? "")
                .components(separatedBy: "\n").filter { !$0.isEmpty }
            while done < all.count {
                let line = all[done]; done += 1
                await run(line)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func edit(_ n: Note, _ range: NSRange, _ s: String, _ kind: History.Kind) {
        lib.history.willReplace(in: n, range: range, with: s, as: kind)
        n.storage.replaceCharacters(in: range, with: s)
    }

    private static func run(_ line: String) async {
        let w = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard let cmd = w.first else { return }
        let tag = w.count > 1 ? w[1] : ""
        let rest = w.count > 2 ? w[2] : ""
        switch cmd {
        case "new":
            let n = lib.newNote()
            lib.rename(n, to: prefix + tag)
            edit(n, NSRange(location: 0, length: 0), rest, .typing)
            say("new \(tag) done")
        case "append":
            guard let n = note(tag) else { say("append \(tag) missing"); return }
            lib.history.breakTyping()
            edit(n, NSRange(location: n.length, length: 0), rest, .typing)
            say("append \(tag) done length=\(n.length)")
        case "prepend":
            guard let n = note(tag) else { say("prepend \(tag) missing"); return }
            lib.history.breakTyping()
            edit(n, NSRange(location: 0, length: 0), rest, .typing)
            say("prepend \(tag) done length=\(n.length)")
        case "big":
            guard let n = note(tag), let count = Int(rest) else { say("big \(tag) missing"); return }
            let unit = "Война и мир — War and Peace. "
            let text = String(String(repeating: unit, count: count / unit.count + 1).prefix(count))
            edit(n, NSRange(location: 0, length: n.length), text, .paste)
            say("big \(tag) done length=\(n.length)")
        case "rename":
            guard let n = note(tag) else { say("rename \(tag) missing"); return }
            lib.rename(n, to: prefix + rest)
            say("rename \(tag) \(rest) done")
        case "pin":
            guard let n = note(tag) else { say("pin \(tag) missing"); return }
            lib.pin([n], rest == "1")
            say("pin \(tag) \(rest) done")
        case "movefirst":   // to the top of its own group, manual order only
            guard let n = note(tag) else { say("movefirst \(tag) missing"); return }
            let group = lib.notes.filter { $0.pinned == n.pinned }
            lib.move([n], toIndex: lib.notes.firstIndex { $0 === group[0] } ?? 0)
            say("movefirst \(tag) done index=\(lib.notes.firstIndex { $0 === n } ?? -1)")
        case "delete":
            guard let n = note(tag) else { say("delete \(tag) missing"); return }
            lib.delete([n])
            say("delete \(tag) done")
        case "undodelete":   // only a «Delete Note» step that brings back a zz-test note; anything else is redone
            let um = lib.history.undoManager
            guard um.undoActionName == "Delete Note" else { say("undodelete refused: top step is \(um.undoActionName)"); return }
            let before = Set(lib.notes.map(\.id))
            um.undo()
            let back = lib.notes.filter { !before.contains($0.id) }
            if back.allSatisfy({ $0.title.hasPrefix(prefix) }) { say("undodelete done \(back.map(\.title))") }
            else { um.redo(); say("undodelete redone: not ours \(back.map(\.title))") }
        case "sort":
            if let s = Library.Sort(rawValue: tag) { lib.sort = s; say("sort \(tag) done") }
        case "size":
            if let v = Int(tag) { lib.textSize = v; say("size \(tag) done") }
        case "share":   // opens the share sheet of the note on screen, for a screen recording of its animation
            Merum.shared.model.editors.share(); say("share done")
        case "dismiss":
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first?.dismiss(animated: true); say("dismiss done")
        case "fetch":
            Merum.shared.sync?.fetchNow(); say("fetch done")
        case "wait":   // wait <tag> <exists|gone|contains X|pinned 0|1|length N|title NEW> ; 60 s at most
            let t0 = now()
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let cond = parts.first ?? "exists", arg = parts.count > 1 ? parts[1] : ""
            while now() - t0 < 60_000 {
                let n = note(tag)
                let ok: Bool
                switch cond {
                case "exists": ok = n != nil
                case "gone": ok = n == nil
                case "contains": ok = n.map { $0.storage.mutableString.range(of: arg).location != NSNotFound } ?? false
                case "pinned": ok = n.map { $0.pinned == (arg == "1") } ?? false
                case "length": ok = n.map { $0.length == Int(arg) } ?? false
                case "title": ok = note(arg) != nil
                default: ok = false
                }
                if ok { say("wait \(tag) \(rest) ok after \(now() - t0)"); return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            say("wait \(tag) \(rest) timeout")
        case "waitsetting":   // waitsetting sort <value> | size <value>
            let t0 = now()
            while now() - t0 < 60_000 {
                if (tag == "sort" && lib.sort.rawValue == rest) || (tag == "size" && "\(lib.textSize)" == rest) {
                    say("waitsetting \(tag) \(rest) ok after \(now() - t0)"); return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            say("waitsetting \(tag) \(rest) timeout")
        case "list":
            say("list " + lib.notes.filter { $0.title.hasPrefix(prefix) }
                .map { "\($0.title)[\($0.length)\($0.pinned ? ",pinned" : "")]" }.joined(separator: " "))
        case "text":
            guard let n = note(tag) else { say("text \(tag) missing"); return }
            say("text \(tag) " + n.storage.mutableString.substring(to: min(n.length, 300)).replacingOccurrences(of: "\n", with: "⏎"))
        case "cleanup":
            let ours = lib.notes.filter { $0.title.hasPrefix(prefix) }
            lib.delete(ours)
            say("cleanup deleted \(ours.count)")
        default:
            say("unknown \(line)")
        }
    }
}
#endif
