// Trials: scripted checks of the real app, compiled only into an ad hoc build (-D TRIALS, ./build), never a release.
// Merum --data DIR --trial SCRIPT runs SCRIPT's lines once the window is up, writes SCRIPT.out (JSON lines) and quits.
// The notes go to DIR, the clipboard is a private one: nothing of the person's is touched. Keys are real NSEvents
// posted into the app's event queue, so menus' key equivalents, the text system and the input context see them as typed.
//
//   key <chars> <keycode> [cmd] [opt] [ctrl] [shift]   one key press («key n 45 cmd» is ⌘N; «key del 51» is ⌫)
//   type <text>                                         text typed key by key (\n for Return)
//   menu <Menu>/<Item>[/<Item>]                         validates the item, records whether enabled, chooses it
//                                                       (not an event: steps chosen so share one undo group)
//   clip <text>                                         puts text on the private clipboard
//   load <file>                                         a new note with the file's text (as merum-cli new)
//   typebench <n> <where: start|middle|end>             types n characters, recording each one's time to drawn
//   validate <label>                                    records every menu item's enabled state
//   wait <seconds>      dump <label>                    pauses; records the app's state
//   set <defaults key> <value>                          writes a setting (folder paths, booleans)
//   clipfiles a|b, clipdata <uti> <file>, clipload <file>  the private clipboard: file URLs, raw data, a file's text
//   timedpaste, waitchange <s>, text, rects, syncwait <s>, deleteopen, refusal <code> [mods], search <q>, open <n>
//   rename <file>, fieldpaste search|rename|find <file>, selectall [n], savename, jump start|middle|end   (timed)
//   edits <n> <seed>, dirs <file>                       random typed edits; paragraph directions as JSON
#if TRIALS
import AppKit
import Carbon.HIToolbox

@MainActor enum Trial {
    static var out: FileHandle?
    static var scriptDir = ""

    static func record(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        out?.write(d + Data("\n".utf8))
    }

    static func run(_ path: String, app: App) {
        // Never on the person's notes or anything that syncs with an iCloud account: a script that deletes would
        // delete there too. A trial needs --data and runs only while sync is off for that folder.
        guard CommandLine.arguments.contains("--data"), app.sync == nil || app.sync?.anyFolder == false && app.library.store?.dir != Store.defaultDirectory else {
            FileHandle.standardError.write(Data("Trials run only on a --data folder that does not sync.\n".utf8))
            exit(2)
        }
        Clipboard.board = NSPasteboard(name: NSPasteboard.Name("com.geragaraza.merum.trial.\(getpid())"))
        scriptDir = (path as NSString).deletingLastPathComponent
        FileManager.default.createFile(atPath: path + ".out", contents: nil)
        out = FileHandle(forWritingAtPath: path + ".out")
        let lines = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        Task { @MainActor in
            for line in lines where !line.isEmpty && !line.hasPrefix("#") {
                Trace.log("step " + line.prefix(60))
                await step(line, app)
                // Until the keys posted by this step are handled.
                for _ in 0..<100 where NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: false) != nil {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            Clipboard.board.releaseGlobally()
            app.library.flush()
            out?.closeFile()
            exit(0)
        }
    }

    private static func event(_ chars: String, _ code: Int, _ mods: NSEvent.ModifierFlags, _ type: NSEvent.EventType, _ app: App) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: NSApp.keyWindow?.windowNumber ?? app.main.window!.windowNumber, context: nil,
                         characters: chars, charactersIgnoringModifiers: mods.contains(.shift) ? chars.uppercased() : chars,
                         isARepeat: false, keyCode: UInt16(code))
    }

    static func press(_ chars: String, _ code: Int, _ mods: NSEvent.ModifierFlags, _ app: App) {
        // Into the event queue, as the window server's events come: each is dequeued and dispatched by the run loop, so
        // undo groups, menus' key equivalents and the input context see one event a turn.
        if let d = event(chars, code, mods, .keyDown, app) { NSApp.postEvent(d, atStart: false) }
        if let u = event(chars, code, mods, .keyUp, app) { NSApp.postEvent(u, atStart: false) }
    }

    private static func mods(_ words: ArraySlice<String>) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if words.contains("cmd") { f.insert(.command) }
        if words.contains("opt") { f.insert(.option) }
        if words.contains("ctrl") { f.insert(.control) }
        if words.contains("shift") { f.insert(.shift) }
        return f
    }

    private static func findItem(_ path: [String]) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        var item: NSMenuItem?
        for (i, name) in path.enumerated() {
            guard let m = menu else { return nil }
            m.update()
            item = m.items.first { $0.title == name || (i == 0 && $0.submenu?.title == name) }
            menu = item?.submenu
        }
        return item
    }

    static func step(_ line: String, _ app: App) async {
        let w = line.components(separatedBy: " ")
        let rest = line.dropFirst(w[0].count + 1)
        switch w[0] {
        case "key":
            let ch = w[1] == "del" ? "\u{7f}" : w[1] == "ret" ? "\r" : w[1] == "esc" ? "\u{1b}" : w[1] == "tab" ? "\t" : w[1]
            press(ch, Int(w[2]) ?? 0, mods(w[3...]), app)
        case "type":
            for c in String(rest).replacingOccurrences(of: "\\n", with: "\n") {
                if c == "\n" { press("\r", kVK_Return, [], app) } else { press(String(c), 0, [], app) }
            }
        case "menu":
            let path = String(rest).components(separatedBy: "/")
            guard let it = findItem(path), let menu = it.menu else { record(["menu": String(rest), "found": false]); return }
            menu.update()
            record(["menu": String(rest), "enabled": it.isEnabled, "title": it.title])
            if it.isEnabled, let i = menu.items.firstIndex(of: it) { menu.performActionForItem(at: i) }
        case "clip":
            Clipboard.board.clearContents()
            Clipboard.board.setString(String(rest).replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
        case "load":
            let text = (try? String(contentsOfFile: String(rest), encoding: .utf8)) ?? ""
            let t0 = CACurrentMediaTime()
            let name = Commands.new(app.library, text: text, name: nil)
            record(["load": String(rest), "name": name, "ms": (CACurrentMediaTime() - t0) * 1000])
        case "typebench":
            await typeBench(Int(w[1]) ?? 100, w.count > 2 ? w[2] : "end", app)
        case "validate":
            var items: [String: Bool] = [:]
            func walk(_ m: NSMenu, _ prefix: String) {
                m.update()
                for it in m.items where !it.isSeparatorItem && !it.isHidden {
                    let name = prefix + it.title
                    if let s = it.submenu { walk(s, name + "/") } else { items[name] = it.isEnabled }
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            record(["validate": w.count > 1 ? w[1] : "", "items": items])
        case "probe":
            // The first edit of the open note, piece by piece.
            guard let n = app.main.current, let t = app.main.editor.textView, let w = app.main.window else { return }
            var t0 = CACurrentMediaTime()
            app.library.history.willReplace(in: n, range: NSRange(location: 0, length: 0), with: "a")
            let a = CACurrentMediaTime() - t0; t0 = CACurrentMediaTime()
            n.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a")
            let b = CACurrentMediaTime() - t0; t0 = CACurrentMediaTime()
            t.didChangeText()
            w.displayIfNeeded(); CATransaction.flush()
            let c = CACurrentMediaTime() - t0
            record(["probe": true, "historyMs": a * 1000, "storageMs": b * 1000, "drawMs": c * 1000])
        case "size":
            if let win = app.main.window {
                var f = win.frame
                f.size = NSSize(width: Double(w[1]) ?? 0, height: Double(w[2]) ?? 0)
                win.setFrame(f, display: true)
                record(["size": NSStringFromSize(win.frame.size)])
            }
        case "appearance":
            NSApp.appearance = NSAppearance(named: w[1] == "dark" ? .darkAqua : .aqua)
        case "shot":
            // shot <name> [settings]: asks the runner outside for a picture of the window (screencapture -l <id> run by
            // the runner, which has the screen grant): writes <dir>/shot-request «name id» and waits until it is gone.
            let win = w.count > 2 && w[2] == "settings" ? app.settings?.panel : app.main.window
            guard let n = win?.windowNumber else { return }
            app.main.window?.displayIfNeeded()
            let req = scriptDir + "/shot-request"
            try? "\(w[1]) \(n)".write(toFile: req, atomically: true, encoding: .utf8)
            for _ in 0..<100 where FileManager.default.fileExists(atPath: req) { try? await Task.sleep(nanoseconds: 100_000_000) }
            // Also drawn by the app itself (macOS 13 gives no window picture over ssh): the whole frame view, toolbar too.
            if let frameView = win?.contentView?.superview, let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: scriptDir + "/" + w[1] + "-self.png"))
            }
        case "search":
            app.main.list.search(String(rest))
            try? await Task.sleep(nanoseconds: 600_000_000)
        case "refusal":
            // refusal <keycode> [cmd] [opt] [ctrl] [shift]: what the Shortcut recorder says of a key
            let f = mods(w[2...])
            var m = 0
            if f.contains(.command) { m |= cmdKey }; if f.contains(.option) { m |= optionKey }
            if f.contains(.control) { m |= controlKey }; if f.contains(.shift) { m |= shiftKey }
            let sc = Shortcut(key: Int(w[1]) ?? 0, mods: m)
            record(["refusal": sc.title, "says": refusal(sc) ?? "accepted"])
        case "clipfiles":
            // clipfiles <path>|<path>…: files as Finder copies them
            Clipboard.board.clearContents()
            Clipboard.board.writeObjects(String(rest).components(separatedBy: "|").map { NSURL(fileURLWithPath: $0) })
        case "clipdata":
            // clipdata <uti> <file>: one item of raw data (a screenshot's PNG with no file, RTF, HTML)
            let d = (try? Data(contentsOf: URL(fileURLWithPath: String(rest.dropFirst(w[1].count + 1))))) ?? Data()
            Clipboard.board.clearContents()
            Clipboard.board.setData(d, forType: NSPasteboard.PasteboardType(w[1]))
        case "clipload":
            Clipboard.board.clearContents()
            Clipboard.board.setString((try? String(contentsOfFile: String(rest), encoding: .utf8)) ?? "", forType: .string)
        case "timedpaste":
            let t0 = CACurrentMediaTime()
            app.main.editor.textView?.paste(nil)
            app.main.window?.displayIfNeeded(); CATransaction.flush()
            record(["paste": "timed", "ms": (CACurrentMediaTime() - t0) * 1000, "length": app.main.current?.length ?? 0])
        case "waitchange":
            // waitchange <seconds>: until the open note's length changes (a picture's text arriving)
            let start = app.main.current?.length ?? 0
            for _ in 0..<Int((Double(w[1]) ?? 10) * 10) where (app.main.current?.length ?? 0) == start {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        case "text":
            record(["text": app.main.editor.textView?.string ?? ""])
        case "rects":
            // Screen rectangles (points, top-left origin, as CGEvent takes them) of the list rows and the text, for
            // mouse events posted from outside.
            guard let win = app.main.window, let screen = win.screen ?? NSScreen.screens.first else { return }
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            func g(_ v: NSView, _ r: NSRect) -> [Double] {
                let s = win.convertToScreen(v.convert(r, to: nil))
                return [s.midX, top - s.midY, s.width, s.height]
            }
            let t = app.main.list.table
            var rows: [[Double]] = []
            for i in 0..<t.numberOfRows { rows.append(g(t, t.rect(ofRow: i))) }
            var o: [String: Any] = ["rows": rows]
            if let tv = app.main.editor.textView, let sv = tv.enclosingScrollView { o["text"] = g(sv, sv.bounds) }
            let lv = t.enclosingScrollView!
            o["listEmpty"] = g(lv, NSRect(x: 20, y: lv.bounds.maxY - 30, width: 10, height: 10))
            record(o)
        case "syncwait":
            // syncwait <seconds>: until a sync run ends; records how
            guard let sync = app.sync else { record(["sync": "off"]); return }
            var result: String?
            sync.onRunEnded = { e in result = e.map { "\($0)" } ?? "ok" }
            sync.fetchNow()
            for _ in 0..<Int((Double(w[1]) ?? 30) * 10) where result == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            app.library.flush()
            let state = (try? String(contentsOf: app.library.store!.dir.appendingPathComponent("sync.json"), encoding: .utf8)) ?? ""
            record(["sync": result ?? "timeout", "syncJSON": String(state.prefix(400))])
        case "deletematch":
            // deletematch <text>: deletes only the notes whose text holds it
            let q = String(rest)
            let hit = app.library.notes.filter { $0.storage.string.contains(q) }
            app.library.delete(hit)
            record(["deleted": hit.map(\.title)])
        case "deleteopen":
            app.main.deleteOpenNote(nil)
        case "login":
            // login on|off|status: Settings' Open at Login switch
            do { if w[1] == "on" { try loginItem.register() } else if w[1] == "off" { try await loginItem.unregister() } }
            catch { record(["login": w[1], "error": "\(error)"]) }
            record(["login": w[1], "status": ["notRegistered", "enabled", "requiresApproval", "notFound"][min(loginItem.status.rawValue, 3)]])
        case "more":
            // more [seconds]: the «…» menu as it would open, then again after a wait (the counts arriving)
            let m = app.main.more
            app.main.menuNeedsUpdate(m)
            record(["more": m.items.map { $0.isSeparatorItem ? "—" : $0.title }])
            try? await Task.sleep(nanoseconds: UInt64((Double(w.count > 1 ? w[1] : "1") ?? 1) * 1e9))
            record(["moreLater": m.items.map { $0.isSeparatorItem ? "—" : $0.title }])
        case "resizebench":
            // resizebench <frames>: a live resize, the window's width going 100 pt narrower and back, each frame timed to drawn
            guard let win = app.main.window else { return }
            let start = win.frame
            var times: [Double] = []
            let n = Int(w.count > 1 ? w[1] : "60") ?? 60
            for i in 0..<n {
                var f = start
                f.size.width = start.width - CGFloat(i % 20 < 10 ? i % 10 : 10 - i % 10) * 10
                let t0 = CACurrentMediaTime()
                win.setFrame(f, display: false)
                win.layoutIfNeeded(); win.displayIfNeeded(); CATransaction.flush()
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            win.setFrame(start, display: true)
            let s = times.sorted()
            record(["resizebench": n, "medianMs": s[s.count / 2], "maxMs": s.last!, "open": app.main.current?.title ?? "-", "length": app.main.current?.length ?? 0])
        case "manynotes":
            // manynotes <n>: n short notes made at once
            for i in 0..<(Int(w[1]) ?? 10) { _ = Commands.new(app.library, text: "Note text number \(i)", name: nil) }
        case "timeit":
            // timeit deleteall|undo|redo: the list's ⌘A ⌘⌫, or ⌘Z / ⇧⌘Z, timed until the window is drawn again
            let t0 = CACurrentMediaTime()
            switch w[1] {
            case "deleteall": app.main.list.table.selectAll(nil); app.main.list.deleteSelected()
            case "cutall": app.main.editor.textView?.selectAll(nil); app.main.editor.textView?.cut(nil)
            case "paste": app.main.editor.textView?.paste(nil)
            case "undo": app.library.history.undoManager.undo()
            default: app.library.history.undoManager.redo()
            }
            app.main.window?.layoutIfNeeded(); app.main.window?.displayIfNeeded(); CATransaction.flush()
            record(["timeit": w[1], "ms": (CACurrentMediaTime() - t0) * 1000, "notes": app.library.notes.count, "length": app.main.current?.length ?? 0])
        case "toolbarfit":
            // toolbarfit: the narrowest window (sidebar shown, then hidden) at which every toolbar item is in the bar, not in
            // its » overflow; the split view's own minimums switched off meanwhile
            guard let win = app.main.window, let tb = win.toolbar else { return }
            let keepMin = win.minSize
            win.minSize = NSSize(width: 200, height: 200)
            let side = app.main.split.splitViewItems[0], ed = app.main.split.splitViewItems[1]
            let sMin = side.minimumThickness, eMin = ed.minimumThickness
            ed.minimumThickness = 50
            var out: [String: Any] = [:]
            for collapsed in [false, true] {
                side.isCollapsed = collapsed
                try? await Task.sleep(nanoseconds: 400_000_000)
                var smallest = 0.0
                for width in stride(from: 1000.0, through: 300.0, by: -5.0) {
                    var f = win.frame; f.size.width = width
                    win.setFrame(f, display: true)
                    win.layoutIfNeeded()
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    let spacers: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
                    let wanted = Set(tb.items.map(\.itemIdentifier)).subtracting(spacers)
                    let shown = Set((tb.visibleItems ?? []).map(\.itemIdentifier)).subtracting(spacers)
                    if !wanted.isSubset(of: shown) { break }
                    smallest = width
                }
                out[collapsed ? "sidebarHidden" : "sidebarShown"] = smallest
            }
            side.isCollapsed = false
            side.minimumThickness = sMin; ed.minimumThickness = eMin; win.minSize = keepMin
            out["title"] = win.title; out["sidebarWidth"] = side.viewController.view.frame.width
            record(["toolbarfit": out])
        case "rename":
            // rename <file>: the open note gets the file's text as its name (a paste into the rename field), timed until
            // the window is laid out and drawn again
            guard let n = app.main.current else { return }
            let name = (try? String(contentsOfFile: String(rest), encoding: .utf8)) ?? ""
            let t0 = CACurrentMediaTime()
            app.library.rename(n, to: name)
            app.main.window?.layoutIfNeeded(); app.main.window?.displayIfNeeded(); CATransaction.flush()
            record(["rename": (name as NSString).length, "ms": (CACurrentMediaTime() - t0) * 1000])
        case "fieldpaste":
            // fieldpaste search|rename|find <file>: the file's text pasted as ⌘V pastes into that field's editor,
            // timed until the window is laid out and drawn again; then Esc
            guard let win = app.main.window else { return }
            switch w[1] {
            case "search": app.main.searchNotes(nil)
            case "rename": app.main.renameNote(nil)
            default:
                let it = NSMenuItem(); it.tag = NSTextFinder.Action.showFindInterface.rawValue
                app.main.performFindPanelAction(it)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            Clipboard.board.clearContents()
            Clipboard.board.setString((try? String(contentsOfFile: String(rest.dropFirst(w[1].count + 1)), encoding: .utf8)) ?? "", forType: .string)
            let fe = win.firstResponder as? NSTextView
            record(["fieldeditor": w[1], "class": fe.map { String(describing: type(of: $0)) } ?? "none", "same": fe === win.fieldEditor(false, for: nil)])
            let t0 = CACurrentMediaTime()
            // ⌘V's own path (paste: reads the pasteboard with readSelection(from:type:)), on the private clipboard
            _ = fe?.readSelection(from: Clipboard.board, type: .string)
            win.layoutIfNeeded(); win.displayIfNeeded(); CATransaction.flush()
            let ms = (CACurrentMediaTime() - t0) * 1000
            record(["fieldpaste": w[1], "ms": ms, "fieldEditor": fe?.isFieldEditor ?? false, "length": (fe?.string as NSString?)?.length ?? -1,
                    "tk2": fe?.textLayoutManager != nil])
            try? await Task.sleep(nanoseconds: 300_000_000)
            let t1 = CACurrentMediaTime()
            press("\u{1b}", kVK_Escape, [], app)
            for _ in 0..<50 where NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: false) != nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            win.layoutIfNeeded(); win.displayIfNeeded(); CATransaction.flush()
            record(["fieldpasteEsc": w[1], "ms": (CACurrentMediaTime() - t1) * 1000, "title": String(win.title.prefix(40))])
        case "selectall":
            // selectall [n]: ⌘A's action in the note n times, each timed until drawn
            guard let t = app.main.editor.textView, let win = app.main.window else { return }
            var times: [Double] = []
            for _ in 0..<(Int(w.count > 1 ? w[1] : "1") ?? 1) {
                t.setSelectedRange(NSRange(location: 0, length: 0)); win.displayIfNeeded()
                let t0 = CACurrentMediaTime()
                t.selectAll(nil)
                win.displayIfNeeded(); CATransaction.flush()
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            record(["selectall": times.count, "ms": times, "length": app.main.current?.length ?? 0])
        case "jump":
            // jump start|middle|end: the caret put there, its line scrolled into view and drawn, each part timed
            guard let t = app.main.editor.textView, let win = app.main.window else { return }
            let len = (t.string as NSString).length
            let loc = w[1] == "start" ? 0 : w[1] == "middle" ? len / 2 : len
            var t0 = CACurrentMediaTime()
            t.setSelectedRange(NSRange(location: loc, length: 0))
            let a = CACurrentMediaTime() - t0; t0 = CACurrentMediaTime()
            t.scrollRangeToVisible(t.selectedRange())
            let b = CACurrentMediaTime() - t0; t0 = CACurrentMediaTime()
            win.displayIfNeeded(); CATransaction.flush()
            let c = CACurrentMediaTime() - t0
            record(["jump": w[1], "selectMs": a * 1000, "scrollMs": b * 1000, "drawMs": c * 1000])
        case "edits":
            // edits <n> <seed>: n random edits of the open note as typed (insertions of letters of several scripts and line
            // breaks, deletions, joins of paragraphs), at random places
            guard let t = app.main.editor.textView else { return }
            var rng = UInt64(w.count > 2 ? w[2] : "1") ?? 1
            func next(_ m: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(max(m, 1))) }
            let bits = ["a", "ש", "م", "1", " ", "\n", "\u{2067}", "\u{2069}", "!", "Я", "😀"]
            for _ in 0..<(Int(w[1]) ?? 100) {
                let len = (t.string as NSString).length
                let at = next(len + 1)
                if next(3) == 0, len > 0 {
                    let r = (t.string as NSString).rangeOfComposedCharacterSequence(at: max(0, min(at, len - 1)))
                    t.setSelectedRange(r); t.deleteBackward(nil)
                } else {
                    t.setSelectedRange(NSRange(location: at, length: 0))
                    t.insertText((0..<(1 + next(4))).map { _ in bits[next(bits.count)] }.joined(), replacementRange: t.selectedRange())
                }
            }
            record(["edits": w[1], "length": (t.string as NSString).length])
        case "dirs":
            // dirs <file>: the open note's text and each paragraph's direction as set (0 left to right, 1 right to left, -1
            // none), as JSON, for a check from outside
            guard let n = app.main.current else { return }
            let st = n.storage, str = st.mutableString
            var paras: [[Int]] = []
            var loc = 0
            while loc < str.length {
                let r = str.paragraphRange(for: NSRange(location: loc, length: 0))
                let ps = st.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
                let d = ps.map { $0.baseWritingDirection == .rightToLeft ? 1 : $0.baseWritingDirection == .leftToRight ? 0 : -1 } ?? -1
                var uniform = true
                st.enumerateAttribute(.paragraphStyle, in: r) { v, _, stop in
                    if (v as? NSParagraphStyle)?.baseWritingDirection != ps?.baseWritingDirection { uniform = false; stop.pointee = true } }
                paras.append([r.location, r.length, d, uniform ? 1 : 0])
                loc = NSMaxRange(r)
            }
            let o: [String: Any] = ["text": st.string, "paras": paras]
            if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: URL(fileURLWithPath: String(rest))) }
            record(["dirs": paras.count])
        case "savename":
            // savename: the file name ⌘S would give the open note, timed
            guard let n = app.main.current else { return }
            let t0 = CACurrentMediaTime()
            let f = Saver.fileName(n.title)
            record(["savename": f.utf8.count, "ms": (CACurrentMediaTime() - t0) * 1000])
        case "clickempty":
            app.main.list.clickedEmpty()
        case "open":
            if let i = Int(w[1]), i <= app.main.list.notes.count { app.main.open(app.main.list.notes[i - 1], focus: false) }
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(w[1]) ?? 1) * 1e9))
        case "set":
            let v = String(rest.dropFirst(w[1].count + 1))
            if v == "true" || v == "false" { UserDefaults.standard.set(v == "true", forKey: w[1]) }
            else if v == "nil" { UserDefaults.standard.removeObject(forKey: w[1]) }
            else { UserDefaults.standard.set(v, forKey: w[1]) }
        case "dump":
            record(state(w.count > 1 ? w[1] : "", app))
        default:
            record(["unknown": line])
        }
    }

    static func state(_ label: String, _ app: App) -> [String: Any] {
        let lib = app.library, m = app.main!
        let t = m.editor.textView
        let text = t?.string ?? ""
        let fr = m.window?.firstResponder
        var o: [String: Any] = [
            "dump": label,
            "notes": lib.notes.map(\.title),
            "open": m.current?.title ?? "-",
            "title": m.window?.title ?? "",
            "length": (text as NSString).length,
            "head": String(text.prefix(60)),
            "selection": t.map { NSStringFromRange($0.selectedRange()) } ?? "",
            "responder": fr.map { String(describing: type(of: $0)) } ?? "nil",
            "fieldLength": (fr as? NSTextView).map { $0.isFieldEditor ? ($0.string as NSString).length : -1 } ?? -1,
            "listSelection": Array(m.list.table.selectedRowIndexes),
            "rows": m.list.rows.map { r -> String in if case .header(let h) = r { return "[" + h + "]" }; return r.note!.title },
            "lengths": lib.notes.map(\.length),
            "textSize": lib.textSize,
            "fontSize": (t?.typingAttributes[.font] as? NSFont)?.pointSize ?? 0,
            "sort": lib.sort.rawValue, "ascending": lib.ascending,
            "undo": lib.history.undoManager.canUndo ? lib.history.undoManager.undoMenuItemTitle : "-",
            "redo": lib.history.undoManager.canRedo ? lib.history.undoManager.redoMenuItemTitle : "-",
            "clip": String((Clipboard.board.string(forType: .string) ?? "").prefix(80)),
            "level": m.window?.level.rawValue ?? -1,
            "visible": m.window?.isVisible ?? false,
            "key": m.window?.isKeyWindow ?? false,
            "policy": NSApp.activationPolicy().rawValue,
            "active": NSApp.isActive,
            "frame": NSStringFromRect(m.window?.frame ?? .zero),
            "findBar": t?.enclosingScrollView?.isFindBarVisible ?? false,
            "sidebarCollapsed": (m.split.splitViewItems.first?.isCollapsed ?? false),
            "settings": app.settings?.panel.isVisible ?? false,
            "footprintMB": footprintMB(),
            "counter": m.editor.counter.stringValue,
            "editorSubviews": m.editor.view.subviews.count,
            "layoutManagers": lib.notes.reduce(0) { $0 + $1.storage.layoutManagers.count },
            "tableRows": m.list.table.numberOfRows,
        ]
        if let s = Saver.folder { o["saved"] = (try? FileManager.default.contentsOfDirectory(atPath: s.path))?.sorted() ?? [] }
        return o
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? (Double(info.phys_footprint) / 1048576).rounded() : -1
    }

    /// Typing measured as the person meets it: each key from its event to the window drawn, and the longest gap the
    /// main thread had between run-loop turns while typing.
    static func typeBench(_ n: Int, _ place: String, _ app: App) async {
        guard let t = app.main.editor.textView, let w = app.main.window else { return }
        let len = (t.string as NSString).length
        let loc = place == "start" ? 0 : place == "middle" ? len / 2 : len
        t.setSelectedRange(NSRange(location: loc, length: 0))
        t.scrollRangeToVisible(t.selectedRange())
        w.displayIfNeeded()
        var times: [Double] = []
        let letters = Array("съешь же ещё этих мягких французских булок да выпей чаю ")
        var maxGap = 0.0, last = CACurrentMediaTime()
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, act in
            let now = CACurrentMediaTime()
            if act == .afterWaiting { last = now } else { maxGap = max(maxGap, now - last); last = now }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        for i in 0..<n {
            let c = String(letters[i % letters.count])
            let t0 = CACurrentMediaTime()
            // Sent at once rather than queued: the time from the key to the drawn window is measured right here.
            if let d = event(c, 0, [], .keyDown, app) { NSApp.sendEvent(d) }
            if let u = event(c, 0, [], .keyUp, app) { NSApp.sendEvent(u) }
            w.displayIfNeeded()
            CATransaction.flush()
            times.append((CACurrentMediaTime() - t0) * 1000)
            // A fast typist: about 12 keys a second, the run loop free between them (background layout, saves).
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes)
        let s = times.sorted()
        record(["typebench": place, "n": n, "length": len, "medianMs": s[s.count / 2], "p95Ms": s[Int(Double(s.count) * 0.95)],
                "maxMs": s.last!, "maxMainThreadBusyMs": maxGap * 1000])
    }
}
#endif

#if TRIALS
/// --trace FILE: one line per hot-key press and what came of it (show/hide checks over many Space switches).
@MainActor enum Trace {
    static let handle: FileHandle? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--trace"), i + 1 < CommandLine.arguments.count else { return nil }
        let p = CommandLine.arguments[i + 1]
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    static func log(_ s: String) {
        guard let h = handle else { return }
        h.write(Data(String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, s).utf8))
    }
    static func state(_ app: App) -> String {
        let w = app.main.window
        return "shown=\(app.shown) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) visible=\(w?.isVisible ?? false) onActiveSpace=\(w?.isOnActiveSpace ?? false) key=\(w?.isKeyWindow ?? false) policy=\(NSApp.activationPolicy().rawValue) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")"
    }
}
#endif
