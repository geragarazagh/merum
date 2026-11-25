// A note and its default name.
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One note. The text lives only in `storage`, the very object the text view edits: there is no second copy to keep in
/// step, and a ten-million-character note costs one buffer. The core writes plain strings into it; the UI gives the
/// edited ranges their attributes (one font, one colour).
/// Used on the main thread only; what crosses threads is `textSnapshot`, an immutable copy.
final class Note: @unchecked Sendable {
    let id: UUID
    var title: String
    var created: Date
    /// When the text or the title last changed (here or on another device).
    var modified: Date
    /// Place in the manual order: smaller comes first. A Double, so a move changes only the moved notes.
    var position: Double
    /// The person gave it a name; a note that was never renamed carries a default name and may be dropped when left
    /// empty (Library.leave).
    var renamed: Bool
    /// Pinned notes stand apart above the others, as in Apple Notes.
    var pinned: Bool
    let storage: NSTextStorage

    init(id: UUID = UUID(), title: String, created: Date = Date(), modified: Date? = nil, position: Double,
         renamed: Bool = false, pinned: Bool = false, storage: NSTextStorage = NSTextStorage()) {
        self.id = id
        self.title = title
        self.created = created
        self.modified = modified ?? created
        self.position = position
        self.renamed = renamed
        self.pinned = pinned
        self.storage = storage
    }

    /// The whole text as an immutable copy, for a snapshot that may outlive later edits (a write, an upload).
    /// Copying the backing buffer takes ~1 ms per 10 M characters; bridging `storage.string` would not copy and could
    /// change under a reader on another thread.
    var textSnapshot: NSString { storage.mutableString.copy() as! NSString }

    var length: Int { storage.length }
}

/// English ordinal words for default names: 1 "First", 21 "Twenty-First", 100 "One Hundredth", 101 "One Hundred First",
/// 1000 "One Thousandth", in title case as a name is written. American usage: no «and» inside a number, a hyphen only
/// between tens and ones.
enum Ordinal {
    private static let ones = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten",
                               "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen",
                               "Eighteen", "Nineteen"]
    private static let tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"]
    private static let scales = ["", "Thousand", "Million", "Billion", "Trillion", "Quadrillion", "Quintillion"]
    private static let irregular = ["One": "First", "Two": "Second", "Three": "Third", "Five": "Fifth",
                                    "Eight": "Eighth", "Nine": "Ninth", "Twelve": "Twelfth"]

    /// Cardinal words of 1...999.
    private static func below1000(_ n: Int) -> [String] {
        var out: [String] = []
        if n >= 100 { out += [ones[n / 100], "Hundred"] }
        let r = n % 100
        if r >= 20 { out.append(r % 10 == 0 ? tens[r / 10] : tens[r / 10] + "-" + ones[r % 10]) }
        else if r > 0 { out.append(ones[r]) }
        return out
    }

    /// Cardinal words, "One Hundred Twenty-One". n >= 1.
    static func cardinal(_ n: Int) -> String {
        precondition(n >= 1)
        var words: [String] = []
        var rest = n, scale = 0
        while rest > 0 {
            let chunk = rest % 1000
            if chunk > 0 { words.insert(contentsOf: below1000(chunk) + (scale > 0 ? [scales[scale]] : []), at: 0) }
            rest /= 1000; scale += 1
        }
        return words.joined(separator: " ")
    }

    /// Ordinal words, "One Hundred Twenty-First". n >= 1.
    static func words(_ n: Int) -> String {
        var words = cardinal(n).components(separatedBy: " ")
        // Only the last word (and in it only the part after a hyphen) turns ordinal: "Twenty-One" -> "Twenty-First".
        var parts = words[words.count - 1].components(separatedBy: "-")
        parts[parts.count - 1] = ordinalWord(parts[parts.count - 1])
        words[words.count - 1] = parts.joined(separator: "-")
        return words.joined(separator: " ")
    }

    private static func ordinalWord(_ w: String) -> String {
        if let o = irregular[w] { return o }
        if w.hasSuffix("y") { return String(w.dropLast()) + "ieth" }   // Twenty -> Twentieth
        return w + "th"                                                  // Four -> Fourth, Hundred -> Hundredth
    }

    /// "First Note".
    static func noteName(_ n: Int) -> String { words(n) + " Note" }
}
