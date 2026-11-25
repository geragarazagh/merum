// The app's own editor with «War and Peace» and ten million characters, timed the way the engine bench timed
// UITextView (AGENTS.md, «Measured (iPhone)»): main-thread work including layout and the drawing of the next frame.
// Run on a phone: xcodebuild test -only-testing:MerumTests/PhoneTests -destination id=<udid>
import QuartzCore
import UIKit
import XCTest
@testable import Merum

@MainActor final class PhoneTests: XCTestCase {
    private func ms(_ s: Double) -> Double { (s * 10000).rounded() / 10 }
    private func flush(_ v: UIView) { v.layoutIfNeeded(); CATransaction.flush() }
    private func frame() { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)) }
    private func time(_ v: UIView, _ body: () -> Void) -> Double {
        let t = CACurrentMediaTime(); body(); flush(v); let w = ms(CACurrentMediaTime() - t); frame(); return w
    }
    private func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (Double(info.phys_footprint) / 1_048_576).rounded()
    }
    private func stat(_ a: [Double]) -> String {
        let s = a.sorted()
        return "\(s[s.count / 2]) / \(s.last!)"
    }
    private func log(_ k: String, _ v: Any) { print("MERUMPHONE \(k) \(v)") }

    func testBigNotes() throws {
        for file in ["war-and-peace", "ten-million"] { try run(file) }
    }

    private func run(_ file: String) throws {
        let url = Bundle(for: PhoneTests.self).url(forResource: file, withExtension: "txt")!
        let text = try String(contentsOf: url, encoding: .utf8)
        let lib = Library()
        let small = Note(title: "Small", position: 1, storage: NSTextStorage(string: "Milk, bread."))
        let big = Note(title: file, position: 2, storage: NSTextStorage(string: text))
        lib.restore([small, big])
        let model = Model(library: lib)
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!.windows.first!
        let host = model.editors.container
        host.frame = w.bounds
        w.addSubview(host)
        defer { host.removeFromSuperview() }
        model.show(small); model.editors.showCurrent(); flush(host)
        for _ in 0..<10 { frame() }
        log("\(file) mem.before", footprint())

        log("\(file) open", time(host) { model.show(big); model.editors.showCurrent() })
        let tv = host.shown!
        log("\(file) mem.open", footprint())
        log("\(file) keyboard.up", time(host) { _ = tv.becomeFirstResponder() })
        for _ in 0..<10 { frame() }

        let len = big.length
        for (name, at) in [("start", 0), ("middle", len / 2), ("end", len)] {
            tv.selectedRange = NSRange(location: at, length: 0); tv.scrollRangeToVisible(tv.selectedRange); frame()
            var keys: [Double] = []
            for _ in 0..<20 {
                keys.append(time(host) {
                    if model.editors.textView(tv, shouldChangeTextIn: tv.selectedRange, replacementText: "ж") { tv.insertText("ж") }
                })
            }
            log("\(file) key.\(name)", stat(keys))
        }
        var scroll: [Double] = []
        tv.scrollRangeToVisible(NSRange(location: len / 2, length: 0)); frame()
        for _ in 0..<240 { scroll.append(time(host) { tv.contentOffset.y += 40 }) }
        log("\(file) scroll.steady", stat(scroll))
        log("\(file) mem.scrolled", footprint())

        // Paste the whole text into a new note through the app's paste path (the core's step, the storage directly).
        let fresh = lib.newNote()
        log("\(file) switch.toNew", time(host) { model.show(fresh); model.editors.showCurrent() })
        let ftv = host.shown!
        _ = ftv.becomeFirstResponder(); frame()
        log("\(file) paste.all", time(host) { model.editors.replace(ftv.selectedRange, with: text, in: ftv, kind: .paste) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var after: [Double] = []
        for _ in 0..<10 {
            after.append(time(host) {
                if model.editors.textView(ftv, shouldChangeTextIn: ftv.selectedRange, replacementText: "ж") { ftv.insertText("ж") }
            })
        }
        log("\(file) key.afterPaste", stat(after))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        log("\(file) undo.typing", time(host) { ftv.undoManager?.undo() })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        log("\(file) undo.paste", time(host) { ftv.undoManager?.undo() })
        XCTAssertEqual(fresh.length, 0)
        log("\(file) redo.paste", time(host) { ftv.undoManager?.redo() })
        XCTAssertEqual(fresh.length, (text as NSString).length)
        log("\(file) select.all", time(host) { ftv.selectAll(nil) })
        // Cut's storage half only: the pasteboard half would carry ten million characters to the Mac's clipboard
        // through Universal Clipboard.
        log("\(file) delete.all", time(host) { model.editors.replace(ftv.selectedRange, with: "", in: ftv, kind: .cut) })
        XCTAssertEqual(fresh.length, 0)
        log("\(file) switch.back", time(host) { model.show(big); model.editors.showCurrent() })
        log("\(file) size.up", time(host) { lib.textSize = 125 })
        log("\(file) size.back", time(host) { lib.textSize = 100 })
        // The bottom bar's counter: what it costs off the main thread once typing pauses.
        let t = CACurrentMediaTime(); _ = Facts(text); log("\(file) counter.offMain", ms(CACurrentMediaTime() - t))
        log("\(file) mem.end", footprint())
        tv.resignFirstResponder(); ftv.resignFirstResponder()
    }
}
