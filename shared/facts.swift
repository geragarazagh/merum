// What the line under a note says of it (and the iPhone's «…» menu): characters, words and ≈ tokens, counted as Copia
// counts. One copy for both apps; counted off the main thread and given up as soon as a newer count is asked for.
import Foundation

/// Counted from hardest fact to loosest, as Copia counts: characters (what a person sees as one: «é», «👍🏽»), words
/// (runs of letters and digits, with - ' ’ inside a word), and an upward-rounded estimate of tokens (about 4 characters
/// of Latin text and 2.8 of Cyrillic per token, measured on Claude's tokenizer for Copia).
struct Facts: Equatable, Sendable {
    let characters: Int
    let words: Int
    let tokens: Int

    init(characters: Int, words: Int, tokens: Int) {
        self.characters = characters; self.words = words; self.tokens = tokens
    }

    /// Counts at once, on the calling thread.
    init(_ s: String) { self = Facts.count(s, cancelled: { false })! }

    /// Counts a note's text: the copy is taken here (~1.6 ms per 10 M characters, on the main thread), the count runs
    /// on another thread. nil when cancelled (the task that called it was cancelled: the text changed again). Typical
    /// use: in the UI's task, after a pause in typing, `facts = await Facts.of(note.textSnapshot)`.
    static func of(_ text: NSString) async -> Facts? {
        let job = Snapshot(text: text)
        let worker = Task.detached(priority: .utility) { () -> Facts? in
            Facts.count(job.text as String, cancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private struct Snapshot: @unchecked Sendable { let text: NSString }   // immutable copy

    /// One pass over the characters; `cancelled` is asked every 64 K characters.
    static func count(_ s: String, cancelled: () -> Bool) -> Facts? {
        var chars = 0, words = 0, inWord = false, cyr = 0, other = 0
        for ch in s {
            chars += 1
            if chars & 0xFFFF == 0, cancelled() { return nil }
            let w = ch.isLetter || ch.isNumber
            if w && !inWord { words += 1 }
            inWord = w || (inWord && (ch == "-" || ch == "'" || ch == "’"))
            for u in ch.unicodeScalars { if (0x0400...0x04FF).contains(u.value) { cyr += 1 } else { other += 1 } }
        }
        return Facts(characters: chars, words: words, tokens: Facts.roundUp(Double(cyr) / 2.8 + Double(other) / 4))
    }

    /// Rounded upward so an estimate never claims false precision (2 416 → 2 450, 19 941 → 20 000).
    static func roundUp(_ x: Double) -> Int {
        guard x > 0 else { return 0 }
        if x < 10 { return Int(ceil(x)) }
        let step: Double = x < 100 ? 5 : x < 1000 ? 10 : x < 10000 ? 50 : 100
        return Int(ceil(x / step) * step)
    }

    static func counted(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted(.number)) \(n == 1 ? one : many)"
    }
    /// One line, as Copia's facts line: «24 characters · 4 words · ≈ 7 tokens».
    var line: String {
        [Facts.counted(characters, "character", "characters"), Facts.counted(words, "word", "words"),
         "≈\u{00A0}" + Facts.counted(tokens, "token", "tokens")].joined(separator: " · ")
    }
    /// Capitalised, one per line or row: «1,234 Characters», «210 Words», «≈ 350 Tokens».
    var lines: [String] {
        [Facts.counted(characters, "Character", "Characters"), Facts.counted(words, "Word", "Words"),
         "≈\u{00A0}" + Facts.counted(tokens, "Token", "Tokens")]
    }
}
