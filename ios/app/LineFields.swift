// What a one-line field takes from a paste or a drop: one line, at most `LineFields.limit` characters.
//
// Why (stress pass 2026-11-27): on iOS 26.0 a paste of 366 K to 10 M characters into the list's search field stopped
// the process inside Apple's text layout (EXC_BREAKPOINT in CFRelease under UIFieldEditor scrollSelectionToVisible,
// no Merum frame); 2.7 M characters first froze the main thread 150 s (UITextField hitTest measures its whole text).
// iOS 27.2 survives it, slowly. A one-line field has no use for more than a line: the search, the Rename field, the
// editor's title and Find in Note get the pasted text with line breaks and control characters as spaces (the core's
// rename does the same with line breaks) and cut at the limit, on a character boundary. The note's own text view is
// not a UITextField and keeps everything (its paste is shared/paste.swift).
//
// SwiftUI owns these fields and their delegates, so the cap rides on UIKit's paste delegate (a separate property,
// left nil by SwiftUI), set whenever a field begins editing: no field can take a paste before that.
import UIKit

@MainActor final class LineFields: NSObject, UITextPasteDelegate {
    /// UTF-16 units a one-line field may hold after a paste. Far above any name or search, far below the sizes
    /// that hurt (hundreds of thousands).
    static let limit = 1_000
    private static let shared = LineFields()   // pasteDelegate is weak
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification,
                                                          object: nil, queue: nil) { n in
            let field = n.object as? UITextField
            MainActor.assumeIsolated {
                // Another delegate set by UIKit or SwiftUI is left alone.
                if let field, field.pasteDelegate == nil { field.pasteDelegate = shared }
            }
        }
    }

    nonisolated func textPasteConfigurationSupporting(_ supporting: UITextPasteConfigurationSupporting,
                                                      combineItemAttributedStrings itemStrings: [NSAttributedString],
                                                      for textRange: UITextRange) -> NSAttributedString {
        MainActor.assumeIsolated {
            var room = Self.limit
            if let field = supporting as? UITextField {
                let whole = field.text?.utf16.count ?? 0
                let replaced = field.offset(from: textRange.start, to: textRange.end)
                room = max(0, Self.limit - (whole - replaced))
            }
            // Joined as UIKit joins several items (one per line), then made one line.
            return NSAttributedString(string: Self.line(itemStrings.map(\.string).joined(separator: "\n"), max: room))
        }
    }

    /// `text` as one line of at most `max` UTF-16 units: line breaks, tabs and other control characters become
    /// spaces, runs of them one space; cut at a character boundary (a cluster longer than the room is cut by
    /// scalar, never inside a surrogate pair).
    nonisolated static func line(_ text: String, max: Int) -> String {
        guard max > 0 else { return "" }
        let ns = text as NSString
        // Only what can survive the cut is cleaned: a 10 M paste costs a scan of a few thousand units.
        var head = text
        if ns.length > max * 4 {
            let at = ns.rangeOfComposedCharacterSequence(at: max * 4).location
            head = ns.substring(to: at > 0 ? at : safeCut(ns, max * 4))
        }
        var out = String.UnicodeScalarView()
        var lastSpace = false
        for s in head.unicodeScalars {
            // Cc only: format characters (joiners, direction marks) are part of the text.
            if s.properties.generalCategory == .control || CharacterSet.newlines.contains(s) {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(s)
                lastSpace = false
            }
        }
        head = String(out)
        let h = head as NSString
        guard h.length > max else { return head }
        var end = h.rangeOfComposedCharacterSequence(at: max).location
        if end == 0 { end = safeCut(h, max) }   // one cluster longer than the room
        return h.substring(to: end)
    }

    /// The largest cut at or below `max` that does not split a surrogate pair.
    private nonisolated static func safeCut(_ s: NSString, _ max: Int) -> Int {
        CFStringIsSurrogateLowCharacter(s.character(at: max)) ? max - 1 : max
    }
}
