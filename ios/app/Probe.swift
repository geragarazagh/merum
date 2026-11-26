// Simulator-only, Debug-only measuring of the editor's animations (nothing of this exists in a device build):
//   -merumSeed <k>   empties the simulator's store and makes the bench notes: a short note, a medium one (60 lines), a
//                    long one («War and Peace» from -merumBook, or a generated 3 M characters); opens the k-th (0-based)
//                    and writes them to disk, so a later plain launch opens on it as the person's last note.
//   -merumProbe      every frame, as drawn (presentation layers), writes to tmp/probe.txt: every counter bar in every
//                    window of the app (keyboard windows included) with its top on screen and its opacity, every
//                    snapshot or portal view (a copy of a bar the system may draw during a transition), the keyboard's
//                    top, the text's scroll and the caret. A UI test drives the screen; a script reads the file.
#if DEBUG && targetEnvironment(simulator)
import UIKit

@MainActor final class Probe: NSObject {
    static let shared = Probe()
    private var link: CADisplayLink?
    private var out: FileHandle?
    private var buffer = ""
    private var frames = 0

    static func runIfAsked() {
        let args = SimulatorModes.args
        if let i = args.firstIndex(of: "-merumSeed") {
            let k = i + 1 < args.count ? Int(args[i + 1]) ?? 0 : 0
            seed(open: k)
        }
        if args.contains("-merumProbe") { shared.start() }
    }

    // MARK: seed

    private static func seed(open k: Int) {
        let lib = Merum.shared.library, model = Merum.shared.model
        lib.delete(lib.notes)
        lib.history.undoManager.removeAllActions()
        lib.sort = .manual
        lib.textSize = 100
        func make(_ text: String, _ name: String) -> Note {
            let n = lib.newNote()
            n.storage.mutableString.setString(text)
            lib.rename(n, to: name)
            return n
        }
        let short = make("Milk\nEggs\nRye bread\nLemons", "Short")
        let medium = make((1...60).map { "Line \($0): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n"), "Medium")
        let path = SimulatorModes.args.firstIndex(of: "-merumBook").flatMap { $0 + 1 < SimulatorModes.args.count ? SimulatorModes.args[$0 + 1] : nil }
        let book = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            ?? String(repeating: "Война и мир. War and Peace. ", count: 110_000)
        let long = make(book, "Long")
        lib.history.undoManager.removeAllActions()
        let target = [short, medium, long][min(max(k, 0), 2)]
        model.path = []
        model.show(target)
        model.path = [.editor]
        lib.flush()
    }

    // MARK: probe

    private func start() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        out = try? FileHandle(forWritingTo: url)
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { Probe.shared.flush() } }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        out?.write(buffer.data(using: .utf8)!)
        buffer = ""
    }

    /// Where a view is drawn this frame, in screen points, and how opaque (the presentation tree).
    private static func drawn(_ v: UIView) -> (CGRect, Float)? {
        guard let w = v.window else { return nil }
        let l = v.layer.presentation() ?? v.layer
        let root = w.layer.presentation() ?? w.layer
        let r = l.convert(l.bounds, to: root).offsetBy(dx: w.frame.minX, dy: w.frame.minY)
        var a: Float = 1
        var cur: UIView? = v
        while let c = cur {
            if c.isHidden { return (r, 0) }
            a *= (c.layer.presentation() ?? c.layer).opacity
            cur = c.superview
        }
        return (r, a)
    }

    private static func all(_ v: UIView, _ body: (UIView) -> Void) {
        body(v)
        for s in v.subviews { all(s, body) }
    }

    private static var windows: [UIWindow] {
        // The keyboard's windows are not in the scene's list; UIKit's own list has them.
        (UIApplication.shared.value(forKey: "windows") as? [UIWindow]) ?? []
    }

    @objc private func tick(_ link: CADisplayLink) {
        frames += 1
        var bars: [String] = []
        var copies: [String] = []
        var kb = "-"
        for w in Probe.windows where !w.isHidden {
            Probe.all(w) { v in
                let name = NSStringFromClass(type(of: v))
                if v is KeyboardBar, let b = v.subviews.first(where: { $0 is UIButton }), let (r, a) = Probe.drawn(b), a > 0.01,
                   let (whole, _) = Probe.drawn(v) {
                    // The row's top (the 44-point button sits 6 points into the 56-point row) and the bar's height.
                    bars.append(String(format: "%.1f/%.2f/h%.0f", r.minY - 6, a, whole.height))
                } else if name.contains("Snapshot") || name.contains("Portal") || name.contains("Replicant") {
                    if let (r, a) = Probe.drawn(v), a > 0.01, r.height > 20, r.height < 200 {
                        copies.append(String(format: "%@:%.1f+%.0f/%.2f", name, r.minY, r.height, a))
                    }
                } else if name == "UIInputSetHostView", let (r, _) = Probe.drawn(v) {
                    kb = String(format: "%.1f", r.minY)
                }
            }
        }
        var text = "-"
        if let tv = Merum.shared.model.editors.container.shown, tv.window != nil {
            let l = tv.layer.presentation() ?? tv.layer
            let caret = tv.caretRect(for: tv.selectedTextRange?.end ?? tv.endOfDocument)
            let onScreen = tv.convert(caret, to: nil)
            text = String(format: "off=%.1f inset=%.0f/%.0f caret=%d/%d caretY=%.1f", l.bounds.minY,
                          tv.adjustedContentInset.top, tv.adjustedContentInset.bottom,
                          tv.selectedRange.location, tv.textStorage.length, onScreen.minY - (l.bounds.minY - tv.bounds.minY))
        }
        let up = Merum.shared.model.keyboardUp ? 1 : 0
        let fr = Merum.shared.model.editors.container.window?.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        text += " fr=" + (fr.components(separatedBy: ".").last ?? fr)
        let ed = Merum.shared.model.editors!
        text += String(format: " under=%.0f wsafe=%.0f", ed.bar.under, ed.container.window?.safeAreaInsets.bottom ?? -1)
        buffer += String(format: "%.4f up=%d kb=%@ bars=%@ copies=%@ %@\n", link.timestamp, up, kb,
                         bars.joined(separator: ","), copies.joined(separator: ","), text)
    }
}
#endif
