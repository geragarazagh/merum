// Each paragraph's writing direction, decided the same way on the Mac and the iPhone: both editors are TextKit 1 over
// the note's NSTextStorage, and both call Direction.fix on every character change and on a whole text given a new
// font (mac/editor.swift, ios/app/Editor.swift).
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Each paragraph's base writing direction, set explicitly as its own paragraph style instead of being left «natural».
///
/// Why, on both: a paragraph that begins in Hebrew or Arabic reads right to left from the right edge, as TextKit 2
/// (TextEdit and Notes on the Mac, Notes on the iPhone) lays it out; TextKit 1's natural direction left it at the left
/// edge (measured on macOS 26 and 27 and on iOS 27).
/// Why, on the Mac, for speed too: TextKit 1 resolves a natural direction anew for every line it lays out, and on
/// macOS 26 that pass (CFAttributedStringGetStatisticalWritingDirections) walks the storage's attribute runs well beyond
/// the paragraph: in a text that changes script often (every font fallback is a run) it cost 40 ms a keystroke at 1 M
/// characters and 115-455 ms at 3.9 M in a test machine, and 4 s to show a pasted 3.9 M-character text; a paragraph
/// with an explicit direction skips it (6-10 ms a keystroke, 0.3 s for the paste). macOS 27 does not pay it, 26 does.
/// The direction is the one Unicode's bidi algorithm gives a paragraph (UBA rules P2 and P3: its first strong letter,
/// isolates skipped; none: left to right).
/// Kept per paragraph as the text changes: the edit's paragraphs are looked at again (willProcessEditing); TextKit makes
/// every paragraph's style that of its first character.
@MainActor enum Direction {
    static let ltr = style(.leftToRight)
    static let rtl = style(.rightToLeft)
    private static func style(_ d: NSWritingDirection) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = d
        return p.copy() as! NSParagraphStyle
    }

    /// Every paragraph `range` touches gets its direction; inside one paragraph whose direction stays, only the
    /// edited characters are written, so typing in a huge paragraph costs what it does in a short one.
    static func fix(_ s: NSTextStorage, around range: NSRange) {
        let str = s.mutableString
        guard str.length > 0 else { return }
        // One character past the edit too: text that ends in a line break leaves the rest of its paragraph as a new
        // paragraph after it, whose direction is its own now.
        let at = min(range.location, str.length)
        let whole = str.paragraphRange(for: NSRange(location: at, length: min(range.length + 1, str.length - at)))
        var pending: (style: NSParagraphStyle, range: NSRange)?
        func flush() { if let p = pending { s.addAttribute(.paragraphStyle, value: p.style, range: p.range) }; pending = nil }
        paragraphs(str, whole) { para, rtl in
            let want = rtl ? Self.rtl : Self.ltr
            let target: NSRange
            if para.location >= range.location, NSMaxRange(para) <= NSMaxRange(range) {
                // All of the paragraph came with the edit: it takes the style whatever it had, and nothing is read.
                // Why: reading an attribute makes the storage fix that run's fonts first (fixesAttributesLazily), and
                // for Arabic or Hebrew a fallback font is looked up per character: asked of every paragraph, a whole
                // «War and Peace» with Arabic paragraphs cost 0.2 s on a Mac and 1 s on the iPhone simulator to open,
                // fonts that layout otherwise fixes only for what is shown.
                target = para
            } else if (s.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle)?
                        .baseWritingDirection == want.baseWritingDirection {
                // The paragraph keeps its direction: only what the edit brought in needs the style.
                target = NSIntersectionRange(para, range)
                guard target.length > 0 else { return }
            } else {
                target = para
            }
            if let p = pending, p.style === want, NSMaxRange(p.range) == target.location {
                pending = (want, NSRange(location: p.range.location, length: p.range.length + target.length))
            } else {
                flush()
                pending = (want, target)
            }
        }
        flush()
    }

    /// Calls `body` for each paragraph of `range` (which starts at a paragraph start) with whether UBA P2/P3 make it
    /// right to left. Paragraphs end after LF, CR, CR LF or U+2029, as NSString's paragraphRange(for:) has them.
    static func paragraphs(_ str: NSString, _ range: NSRange, _ body: (NSRange, Bool) -> Void) {
        let chunk = 16_384
        // A raw buffer, not an Array: the iPhone app is built unoptimised for Debug (as installed from Xcode), where
        // each Array subscript is a generic call; the scan of a pasted «War and Peace» took ~60 ms more that way.
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: chunk + 1)
        defer { buf.deallocate() }
        var start = range.location, i = range.location
        let end = NSMaxRange(range)
        var decided: Bool?   // nil: no strong letter yet
        var isolates = 0
        while i < end {
            let n = min(chunk, end - i)
            // One more unit, so a surrogate pair or CR LF split by the chunk's end is read whole.
            let extra = i + n < str.length ? 1 : 0
            str.getCharacters(buf, range: NSRange(location: i, length: n + extra))
            var k = 0
            while k < n {
                if decided != nil {
                    // Decided: only the paragraph's end matters, so the rest of it is passed in a tight loop.
                    while k < n, buf[k] != 0x0A, buf[k] != 0x0D, buf[k] != 0x2029 { k += 1 }
                    if k == n { break }
                }
                let c = buf[k]
                if c == 0x0A || c == 0x0D || c == 0x2029 {
                    var len = k + 1
                    if c == 0x0D, k + 1 < n + extra, buf[k + 1] == 0x0A { len += 1 }
                    let paraEnd = i + len
                    body(NSRange(location: start, length: paraEnd - start), decided ?? false)
                    start = paraEnd; decided = nil; isolates = 0
                    k = len
                    continue
                }
                var step = 1
                if decided == nil {
                    var scalar = UInt32(c)
                    if UTF16.isLeadSurrogate(c), k + 1 < n + extra, UTF16.isTrailSurrogate(buf[k + 1]) {
                        scalar = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(buf[k + 1]) - 0xDC00)
                        step = 2
                    }
                    if scalar < 0x80 {
                        // ASCII: letters are strong left to right, the rest neutral.
                        if isolates == 0, (scalar | 0x20) >= 0x61, (scalar | 0x20) <= 0x7A { decided = false }
                    } else {
                        switch u_charDirection(Int32(bitPattern: scalar)) {
                        case 19, 20, 21: isolates += 1                    // FSI, LRI, RLI
                        case 22: if isolates > 0 { isolates -= 1 }        // PDI
                        case 0: if isolates == 0 { decided = false }      // L
                        case 1, 13: if isolates == 0 { decided = true }   // R, AL
                        default: break
                        }
                    }
                }
                k += step
            }
            // Past the chunk when its last unit began a CR LF or a surrogate pair.
            i += k
        }
        if start < end { body(NSRange(location: start, length: end - start), decided ?? false) }
    }
}

/// ICU's bidi class of a code point (UCharDirection: 0 L, 1 R, 13 AL, 19 FSI, 20 LRI, 21 RLI, 22 PDI, …), from the
/// system's libicucore (linked by ./build, ./test and ios/project.yml), on every macOS and iOS this app runs on.
@_silgen_name("u_charDirection") private func u_charDirection(_ c: Int32) -> Int32
