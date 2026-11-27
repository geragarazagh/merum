// The toolbar's monkey test, in ad hoc builds only (trial.swift runs it): thousands of random changes as a person makes
// them (Customize Toolbar…'s drops, removals and moves, the default set dragged in, ⌘-drags, resizes, the sidebar
// shown and hidden, the sheet opened and closed), each one through the delegate's own answer, as AppKit asks it before a
// drop; after each, the bar and the window are checked at rest: the fixed start in place, nothing in the » overflow at
// or above the minimum, no layout of the bar while idle, the process's CPU near zero, the right-click menu there, and no
// hang of the main thread (a watchdog thread).
//
//   monkey <n> <seed>     n random actions; one JSON line per failure and a summary
//   idle <seconds>        the bar's layout passes and the process's CPU while nothing happens
//   barcheck <label>      the bar now: its items, what is in the overflow, the right-click menu, idle layout and CPU
#if TRIALS
import AppKit
import ObjectiveC

/// Layout passes of the window's bar (NSToolbarView, AppKit's own view), counted by wrapping its layout method.
enum BarLayouts {
    nonisolated(unsafe) static var count = 0
    /// Layouts of other bars (Customize Toolbar…'s palette and default set are bars of their own), counted apart.
    nonisolated(unsafe) static var others = 0
    nonisolated(unsafe) static weak var window: NSWindow?
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed, let cls = NSClassFromString("NSToolbarView") else { return }
        installed = true
        let sel = #selector(NSView.layout)
        typealias Layout = @convention(c) (AnyObject, Selector) -> Void
        // The class's own layout if it has one, NSView's otherwise (then added to the class, so other views are untouched).
        var own: Method?
        var n: UInt32 = 0
        if let list = class_copyMethodList(cls, &n) {
            for i in 0..<Int(n) where method_getName(list[i]) == sel { own = list[i] }
            free(list)
        }
        let original = unsafeBitCast(method_getImplementation(own ?? class_getInstanceMethod(NSView.self, sel)!), to: Layout.self)
        let block: @convention(block) (AnyObject) -> Void = { view in
            if let w = window, (view as? NSView)?.window === w { count += 1 } else { others += 1 }
            original(view, sel)
        }
        let imp = imp_implementationWithBlock(block)
        if let own { method_setImplementation(own, imp) } else { class_addMethod(cls, sel, imp, "v@:") }
    }
}

/// The longest the main thread went without answering, seen from another thread.
enum Watchdog {
    nonisolated(unsafe) static var beat = CACurrentMediaTime()
    nonisolated(unsafe) static var worst = 0.0
    nonisolated(unsafe) private static var started = false

    @MainActor static func start() {
        guard !started else { return }
        started = true
        let t = Timer(timeInterval: 0.02, repeats: true) { _ in beat = CACurrentMediaTime() }
        RunLoop.main.add(t, forMode: .common)
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.05)
                let gap = CACurrentMediaTime() - beat
                if gap > worst { worst = gap }
                if gap > 5 { FileHandle.standardError.write(Data("watchdog: main thread stuck \(Int(gap)) s\n".utf8)) }
            }
        }
    }
    static func reset() { beat = CACurrentMediaTime(); worst = 0 }
}

@MainActor enum Monkey {
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// The bar's layout passes a second and the CPU share while idle, after a settle.
    static func idle(settle: Double, look: Double) async -> (layouts: Double, cpu: Double) {
        await wait(settle)
        let c0 = BarLayouts.count, t0 = CACurrentMediaTime(), u0 = cpuSeconds()
        await wait(look)
        let dt = CACurrentMediaTime() - t0
        return (Double(BarLayouts.count - c0) / dt, (cpuSeconds() - u0) / dt)
    }

    static func find(_ v: NSView, _ name: String) -> NSView? {
        if String(describing: type(of: v)).contains(name) { return v }
        for s in v.subviews { if let f = find(s, name) { return f } }
        return nil
    }

    /// The menu a right click on the bar would open, asked of the view under the click as AppKit asks it, at the bar's
    /// empty part over the note (or its middle): whether it offers Customize Toolbar….
    static func rightClickMenu(_ win: NSWindow) -> Bool {
        guard let frame = win.contentView?.superview, let bar = find(frame, "NSToolbarView") else { return false }
        let r = bar.convert(bar.bounds, to: nil)
        var points = [NSPoint(x: r.maxX - 12, y: r.midY), NSPoint(x: r.midX, y: r.midY)]
        if let side = win.toolbar?.items.first(where: { $0.itemIdentifier == .sidebarTrackingSeparator })?.view {
            points.insert(NSPoint(x: side.convert(side.bounds, to: nil).maxX + 30, y: r.midY), at: 0)
        }
        for p in points {
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            var v = frame.hitTest(p)
            while let view = v {
                if let m = view.menu(for: e) {
                    if m.items.contains(where: { $0.action == #selector(NSWindow.runToolbarCustomizationPalette(_:)) || $0.title.hasPrefix("Customize Toolbar") }) { return true }
                    break
                }
                v = view.superview
            }
        }
        return false
    }

    /// The bar's items that are buttons (not spaces) and how many of them are out of the overflow; the search as a field.
    static func overflow(_ tb: NSToolbar) -> (wanted: Int, shown: Int, searchFolded: Bool) {
        let spacers: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
        let wanted = tb.items.filter { !spacers.contains($0.itemIdentifier) }.count
        let shown = (tb.visibleItems ?? []).filter { !spacers.contains($0.itemIdentifier) }.count
        var folded = false
        for case let s as NSSearchToolbarItem in tb.items where s.searchField.isHiddenOrHasHiddenAncestor { folded = true }
        return (wanted, shown, folded)
    }

    static func fixedStartHolds(_ tb: NSToolbar) -> Bool {
        let ids = tb.items.map(\.itemIdentifier)
        return MainWindow.repaired(ids) == ids
    }

    static func barcheck(_ label: String, _ app: App) async {
        guard let win = app.main.window, let tb = win.toolbar else { return }
        BarLayouts.window = win; BarLayouts.install(); Watchdog.start()
        let i = await idle(settle: 1.0, look: 2.0)
        let o = overflow(tb)
        Trial.record(["barcheck": label, "bar": tb.items.map(\.itemIdentifier.rawValue), "fixedStart": fixedStartHolds(tb),
                      "buttons": o.wanted, "shown": o.shown, "searchFolded": o.searchFolded, "idleLayoutsPerS": i.layouts,
                      "idleCPU": i.cpu, "rightClickCustomize": rightClickMenu(win), "frame": NSStringFromRect(win.frame),
                      "min": NSStringFromSize(win.minSize), "sidebarCollapsed": app.main.split.splitViewItems[0].isCollapsed,
                      "stored": (UserDefaults.standard.dictionary(forKey: "NSToolbar Configuration Merum")?["TB Item Identifiers"] as? [String]) ?? []])
    }

    /// The window at the minimum plus what a wider sidebar takes, for every sidebar width: the note's part of the bar is
    /// the same width each time, so the bar must show the same.
    static func sidebarSweep(_ app: App) async {
        guard let win = app.main.window, let tb = win.toolbar else { return }
        let m = win.minSize
        var rows: [[String: Any]] = []
        for extra in [0.0, 1, 2, 3, 4, 6, 10] {
            for sb in stride(from: MainWindow.sidebarMin, through: MainWindow.sidebarMax, by: 2) {
                win.setFrame(NSRect(x: 40, y: 40, width: m.width + (sb - MainWindow.sidebarMin) + extra, height: m.height), display: true)
                app.main.split.splitView.setPosition(sb, ofDividerAt: 0)
                win.layoutIfNeeded()
                await wait(0.05)
                let o = overflow(tb)
                let side = app.main.split.splitViewItems[0].viewController.view.frame.width
                if o.shown < o.wanted || o.searchFolded {
                    rows.append(["extra": extra, "sidebarAsked": sb, "sidebar": side, "window": win.frame.width, "shown": o.shown, "wanted": o.wanted, "folded": o.searchFolded])
                }
            }
        }
        Trial.record(["sidebarSweep": NSStringFromSize(m), "bad": rows.count, "rows": Array(rows.prefix(40))])
    }

    /// For several sidebar widths, the narrowest window at which the bar shows everything (scanned point by point from
    /// narrow to wide, and from wide to narrow), the minimum's own sidebar width as reference.
    static func sidebarNeed(_ app: App) async {
        guard let win = app.main.window, let tb = win.toolbar else { return }
        let keep = win.minSize, ed = app.main.split.splitViewItems[1], edMin = ed.minimumThickness
        let sideItem = app.main.split.splitViewItems[0], sideMax = sideItem.maximumThickness
        win.minSize = NSSize(width: 100, height: 100); ed.minimumThickness = 10; sideItem.maximumThickness = MainWindow.sidebarMax
        var out: [[String: Any]] = []
        for sb in stride(from: MainWindow.sidebarMin, through: MainWindow.sidebarMax, by: 8) + [MainWindow.sidebarMax] {
            func ok(_ width: CGFloat) -> Bool? {
                win.setFrame(NSRect(x: 40, y: 40, width: width, height: keep.height), display: true)
                app.main.split.splitView.setPosition(sb, ofDividerAt: 0)
                win.layoutIfNeeded()
                guard abs(sideItem.viewController.view.frame.width - sb) < 0.5 else { return nil }
                let o = overflow(tb); return o.shown >= o.wanted && !o.searchFolded
            }
            var down: CGFloat = 0, up: CGFloat = 0
            _ = ok(sb + 900)
            for wd in stride(from: sb + 700, through: sb + 200, by: -1) { if ok(wd) == true { down = wd } else { break } }
            _ = ok(sb + 250)
            for wd in stride(from: sb + 250, through: sb + 700, by: 1) where ok(wd) == true { up = wd; break }
            out.append(["sb": sb, "noteFromWide": down - sb, "noteFromNarrow": up - sb])
        }
        win.minSize = keep; ed.minimumThickness = edMin; sideItem.maximumThickness = sideMax
        Trial.record(["sidebarNeed": NSStringFromSize(keep), "editorMin": app.main.editorMin, "rows": out])
    }

    static func run(_ n: Int, seed s: UInt64, _ app: App) async {
        guard let win = app.main.window, let tb = win.toolbar, let screen = win.screen ?? NSScreen.main else { return }
        BarLayouts.window = win; BarLayouts.install(); Watchdog.start()
        guard let main = app.main as MainWindow? else { return }
        var seed = s
        func next(_ k: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(k, 1))) }
        let palette = main.toolbarAllowedItemIdentifiers(tb)
        let spaces: Set<NSToolbarItem.Identifier> = [.space, .flexibleSpace]
        let v = screen.visibleFrame
        var fails: [[String: Any]] = []
        var counts: [String: Int] = [:], refused = 0, worstIdleLayouts = 0.0, worstCPU = 0.0, cpuSum = 0.0, checks = 0
        var worstHang = 0.0, menuMissing = 0, overflowAtMin = 0, transient = 0
        let t00 = CACurrentMediaTime()

        /// A drop as the sheet or ⌘-drag makes it: done only where the delegate allows it, as AppKit asks first.
        func insert(_ id: NSToolbarItem.Identifier, at i: Int) -> Bool {
            guard main.toolbar(tb, itemIdentifier: id, canBeInsertedAt: i) else { refused += 1; return false }
            if !spaces.contains(id) && tb.items.contains(where: { $0.itemIdentifier == id }) { return false }
            tb.insertItem(withItemIdentifier: id, at: i); return true
        }
        func remove(at i: Int) -> Bool {
            guard i < tb.items.count, main.toolbar(tb, itemIdentifier: tb.items[i].itemIdentifier, canBeInsertedAt: NSNotFound) else { refused += 1; return false }
            tb.removeItem(at: i); return true
        }

        for step in 0..<n {
            if step % 100 == 0 { FileHandle.standardError.write(Data("monkey \(step)/\(n) \(Int(CACurrentMediaTime() - t00)) s\n".utf8)) }
            let sheet = tb.customizationPaletteIsRunning
            let kinds = ["add", "remove", "move", "defaultSet", "cmdDrag", "resize", "resizeMin", "sidebar", "divider", "sheet"]
            let kind = kinds[next(kinds.count)]
            counts[kind, default: 0] += 1
            Trace.log("monkey step \(step) \(kind) sheet=\(sheet) bar=\(tb.items.count)")
            Watchdog.reset()
            switch kind {
            case "add":
                _ = insert(palette[next(palette.count)], at: next(tb.items.count + 1))
            case "remove":
                _ = remove(at: next(max(tb.items.count, 1)))
            case "move", "cmdDrag":
                // A button taken from one place and dropped at another (the sheet's drag or ⌘-drag in the bar).
                guard !tb.items.isEmpty else { break }
                let from = next(tb.items.count), id = tb.items[from].itemIdentifier
                let to = next(tb.items.count)
                if MainWindow.fixedItems.contains(id) && main.toolbarImmovableItemIdentifiers(tb).contains(id) { refused += 1; break }
                guard main.toolbar(tb, itemIdentifier: id, canBeInsertedAt: to) else { refused += 1; break }
                tb.removeItem(at: from)
                tb.insertItem(withItemIdentifier: id, at: min(to, tb.items.count))
            case "defaultSet":
                // The default set dragged into the bar replaces it whole.
                let d = main.toolbarDefaultItemIdentifiers(tb)
                while !tb.items.isEmpty { tb.removeItem(at: 0) }
                for (i, id) in d.enumerated() { tb.insertItem(withItemIdentifier: id, at: i) }
            case "resize":
                let m = win.minSize
                let wd = m.width + CGFloat(next(Int(max(v.width - m.width, 1)) + 1))
                let ht = m.height + CGFloat(next(Int(max(v.height - m.height, 1)) + 1))
                win.setFrame(NSRect(x: v.minX + CGFloat(next(Int(max(v.width - wd, 1)) + 1)), y: v.minY, width: min(wd, v.width), height: min(ht, v.height)), display: true)
            case "resizeMin":
                let m = win.minSize
                win.setFrame(NSRect(x: v.minX + 30, y: v.minY + 30, width: m.width, height: m.height), display: true)
            case "sidebar":
                main.split.toggleSidebar(nil)
            case "divider":
                if !main.split.splitViewItems[0].isCollapsed {
                    main.split.splitView.setPosition(MainWindow.sidebarMin + CGFloat(next(Int(MainWindow.sidebarMax - MainWindow.sidebarMin) + 40)), ofDividerAt: 0)
                }
            default:   // "sheet": Customize Toolbar… opened, or closed with Done
                if sheet, let s = win.attachedSheet { win.endSheet(s) } else if !sheet { win.runToolbarCustomizationPalette(nil) }
            }
            Trace.log("monkey acted")
            // At rest: the run loop turned (the bar's own layout, our measure a turn later), then looked at.
            var rest = await idle(settle: 0.35, look: 0.3)
            // An animation still running (an item dropped while the sheet is up slides for over half a second) ends; a
            // layout loop does not: a bar still laying itself out a second later is the failure.
            if rest.layouts > 0 || rest.cpu > 0.10 { transient += 1; rest = await idle(settle: 0.7, look: 0.5) }
            Trace.log("monkey rested")
            worstHang = max(worstHang, Watchdog.worst)
            checks += 1; cpuSum += rest.cpu
            worstIdleLayouts = max(worstIdleLayouts, rest.layouts); worstCPU = max(worstCPU, rest.cpu)
            let o = overflow(tb)
            let ids = tb.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
            let running = tb.customizationPaletteIsRunning
            var bad: [String] = []
            if !fixedStartHolds(tb) && !running { bad.append("fixedStart") }
            if rest.layouts > 0 { bad.append("idleLayouts") }
            if rest.cpu > 0.10 { bad.append("idleCPU") }
            if Watchdog.worst > 1.0 { bad.append("hang") }
            // The overflow is judged with the sheet down: while it is up a larger minimum waits for it (window.swift).
            if !running && win.frame.width >= win.minSize.width - 0.5 && (o.shown < o.wanted || o.searchFolded) { bad.append("overflow"); overflowAtMin += 1 }
            if !running && win.frame.width < win.minSize.width - 0.5 { bad.append("belowMinimum") }
            if !running && !rightClickMenu(win) { bad.append("rightClick"); menuMissing += 1 }
            if kind == "sheet" && !sheet && !running { bad.append("sheetDidNotOpen") }
            if !bad.isEmpty && fails.count < 60 {
                fails.append(["step": step, "action": kind, "bad": bad, "bar": ids, "frame": NSStringFromRect(win.frame),
                              "min": NSStringFromSize(win.minSize), "shown": o.shown, "wanted": o.wanted, "layoutsPerS": rest.layouts,
                              "cpu": rest.cpu, "hang": Watchdog.worst, "sheet": running,
                              "collapsed": main.split.splitViewItems[0].isCollapsed])
                Trial.record(fails.last!)
            }
        }
        if let s = win.attachedSheet { win.endSheet(s); await wait(0.6) }
        Trial.record(["monkey": n, "seed": Int(s), "failures": fails.count, "actions": counts, "refusedByDelegate": refused, "settledOnSecondLook": transient,
                      "worstIdleLayoutsPerS": worstIdleLayouts, "worstIdleCPU": worstCPU, "meanIdleCPU": cpuSum / Double(max(checks, 1)),
                      "worstMainThreadGapS": worstHang, "rightClickMissing": menuMissing, "overflowAtOrAboveMin": overflowAtMin,
                      "endBar": tb.items.map(\.itemIdentifier.rawValue), "barLayoutsCounted": BarLayouts.count, "seconds": CACurrentMediaTime() - t00])
    }
}
#endif
