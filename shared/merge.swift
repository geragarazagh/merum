// Text differences for sync: the smallest replacement that turns one text into another, and the three-way merge that
// joins this device's edits and another device's onto the text both started from, never losing a character.
//
// Everything works on UTF-16 code units, the units of NSString and NSTextStorage, so ranges go straight into the
// storage. Speed: common prefix and suffix are found by a plain scan (a few ms for 10 M characters); the line and
// character diffs run only inside the window where both sides changed, which is small for anything a person types.
import Foundation

enum Diff {
    /// The range of `old` to replace and the string to put there to get `new`, keeping the longest common prefix and
    /// suffix; nil when equal. Never cuts a surrogate pair.
    static func minimalReplacement(from old: NSString, to new: NSString) -> (range: NSRange, string: String)? {
        if old.length == new.length && old.isEqual(to: new as String) { return nil }
        return withUnits(old) { a in
            withUnits(new) { b in
                let (p, s) = prefixSuffix(a, b)
                let r = NSRange(location: p, length: a.count - p - s)
                return (r, new.substring(with: NSRange(location: p, length: b.count - p - s)))
            }
        }
    }

    /// Lengths of the common prefix and of the common suffix (not overlapping the prefix), on surrogate-pair
    /// boundaries.
    static func prefixSuffix(_ a: UnsafeBufferPointer<UInt16>, _ b: UnsafeBufferPointer<UInt16>) -> (Int, Int) {
        let n = min(a.count, b.count)
        var p = 0
        // Eight units at a time while they match.
        if let pa = a.baseAddress, let pb = b.baseAddress {
            let ra = UnsafeRawPointer(pa), rb = UnsafeRawPointer(pb)
            while p + 4 <= n && ra.loadUnaligned(fromByteOffset: p * 2, as: UInt64.self) == rb.loadUnaligned(fromByteOffset: p * 2, as: UInt64.self) { p += 4 }
        }
        while p < n && a[p] == b[p] { p += 1 }
        if p > 0 && p < max(a.count, b.count) && isHigh(a[p - 1]) { p -= 1 }
        var s = 0
        let m = n - p
        while s < m && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        if s > 0 && s < max(a.count, b.count) - p && isLow(a[a.count - s]) { s -= 1 }
        return (p, s)
    }

    @inline(__always) static func isHigh(_ u: UInt16) -> Bool { u & 0xFC00 == 0xD800 }
    @inline(__always) static func isLow(_ u: UInt16) -> Bool { u & 0xFC00 == 0xDC00 }

    /// The string's UTF-16 units without a copy when the string keeps them in one piece, else copied once.
    static func withUnits<T>(_ s: NSString, _ body: (UnsafeBufferPointer<UInt16>) -> T) -> T {
        let n = s.length
        if let p = CFStringGetCharactersPtr(s as CFString) {
            return body(UnsafeBufferPointer(start: UnsafePointer(OpaquePointer(p)), count: n))
        }
        var buf = [UInt16](repeating: 0, count: n)
        buf.withUnsafeMutableBufferPointer { s.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: n)) }
        return buf.withUnsafeBufferPointer(body)
    }
}

enum Merge {
    /// Joins this device's text and another device's, both changed from `base`. Changes in different places both
    /// apply; where both changed the same place differently, both versions stay, this device's first, each on its own
    /// line. Without a base (lost), the common start and end of the two count as the base, so both middles stay.
    static func threeWay(base: NSString?, local: NSString, remote: NSString) -> NSString {
        if local.isEqual(to: remote as String) { return local }
        guard let base else {
            return Diff.withUnits(local) { l in
                Diff.withUnits(remote) { r in
                    let (p, s) = Diff.prefixSuffix(l, r)
                    let b = Array(l[0..<p]) + Array(l[(l.count - s)...])
                    return merge(b, Array(l), Array(r))
                }
            }
        }
        if base.isEqual(to: local as String) { return remote }
        if base.isEqual(to: remote as String) { return local }
        return Diff.withUnits(base) { b in Diff.withUnits(local) { l in Diff.withUnits(remote) { r in merge(b, l, r) } } }
    }

    private static func merge<C: RandomAccessCollection>(_ b: C, _ l: C, _ r: C) -> NSString where C.Element == UInt16, C.Index == Int {
        let bArr = UnsafeBufferPointerBox(b), lArr = UnsafeBufferPointerBox(l), rArr = UnsafeBufferPointerBox(r)
        return bArr.with { B in lArr.with { L in rArr.with { R in mergeUnits(B, L, R) } } }
    }

    /// A change: base units [s, e) became `text`.
    struct Hunk { var s: Int; var e: Int; var text: [UInt16] }

    static func mergeUnits(_ B: UnsafeBufferPointer<UInt16>, _ L: UnsafeBufferPointer<UInt16>, _ R: UnsafeBufferPointer<UInt16>) -> NSString {
        // Each side's whole change as one window first.
        let (pl, sl) = Diff.prefixSuffix(B, L)
        let (pr, sr) = Diff.prefixSuffix(B, R)
        let hl = Hunk(s: pl, e: B.count - sl, text: Array(L[pl..<(L.count - sl)]))
        let hr = Hunk(s: pr, e: B.count - sr, text: Array(R[pr..<(R.count - sr)]))
        var out: [UInt16]
        if !overlap(hl, hr) {
            out = apply([hl, hr].sorted { ($0.s, $0.e) < ($1.s, $1.e) }, to: B)
        } else {
            // Both changed around the same place: diff lines inside the joint window, then characters inside a joint
            // hunk that still collides.
            let ws = min(hl.s, hr.s), we = max(hl.e, hr.e)
            let bw = Array(B[ws..<we])
            let lw = Array(L[ws..<(L.count - (B.count - we))])
            let rw = Array(R[ws..<(R.count - (B.count - we))])
            out = Array(B[0..<ws]) + mergeWindow(bw, lw, rw) + Array(B[we...])
        }
        return String(decoding: out, as: UTF16.self) as NSString
    }

    /// Changes that touch the same base text, or begin at the same place (two insertions there, or an insertion
    /// where the other side's change begins): they are looked at together.
    static func overlap(_ a: Hunk, _ b: Hunk) -> Bool {
        strictOverlap(a, b) || a.s == b.s
    }

    /// Changes that cannot both apply as they are: they share base text, or one inserts inside the other's range.
    static func strictOverlap(_ a: Hunk, _ b: Hunk) -> Bool {
        if a.s < b.e && b.s < a.e { return true }
        if a.s == a.e && b.s < a.s && a.s < b.e { return true }
        if b.s == b.e && a.s < b.s && b.s < a.e { return true }
        return false
    }

    static func apply(_ hunks: [Hunk], to b: UnsafeBufferPointer<UInt16>) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(b.count + hunks.reduce(0) { $0 + $1.text.count })
        var at = 0
        for h in hunks {
            out.append(contentsOf: b[at..<h.s])
            out.append(contentsOf: h.text)
            at = max(at, h.e)
        }
        out.append(contentsOf: b[at...])
        return out
    }

    /// Diff3 on lines; colliding line hunks are tried again on characters, and keep both versions if they still
    /// collide.
    static func mergeWindow(_ b: [UInt16], _ l: [UInt16], _ r: [UInt16]) -> [UInt16] {
        let bt = lines(b), lt = lines(l), rt = lines(r)
        var ids: [ArraySlice<UInt16>: Int] = [:]
        func id(_ s: ArraySlice<UInt16>) -> Int { if let i = ids[s] { return i }; let i = ids.count; ids[s] = i; return i }
        let bi = bt.map { id(b[$0]) }, li = lt.map { id(l[$0]) }, ri = rt.map { id(r[$0]) }
        guard let dl = tokenHunks(bi, li), let dr = tokenHunks(bi, ri) else { return bothVersions(b, l, r) }
        // Token hunks to unit hunks.
        func units(_ h: TokenHunk, _ bt: [Range<Int>], _ xt: [Range<Int>], _ x: [UInt16], _ bCount: Int) -> (Int, Int, ArraySlice<UInt16>) {
            let s = h.s < bt.count ? bt[h.s].lowerBound : bCount
            let e = h.e < bt.count ? bt[h.e].lowerBound : bCount
            let xs = h.xs < xt.count ? xt[h.xs].lowerBound : x.count
            let xe = h.xe < xt.count ? xt[h.xe].lowerBound : x.count
            return (s, e, x[xs..<xe])
        }
        var out: [UInt16] = []
        var at = 0          // in base tokens
        var i = 0, j = 0
        let bEnd = { (t: Int) in t < bt.count ? bt[t].lowerBound : b.count }
        while i < dl.count || j < dr.count {
            // Next group: hunks from both sides that collide, transitively.
            var gl: [TokenHunk] = [], gr: [TokenHunk] = []
            var s = Int.max, e = Int.min
            func take(_ h: TokenHunk, left: Bool) { if left { gl.append(h) } else { gr.append(h) }; s = min(s, h.s); e = max(e, h.e) }
            if j >= dr.count || (i < dl.count && dl[i].s <= dr[j].s) { take(dl[i], left: true); i += 1 } else { take(dr[j], left: false); j += 1 }
            var grew = true
            while grew {
                grew = false
                let g = TokenHunk(s: s, e: e, xs: 0, xe: 0)
                if i < dl.count && overlap(g, dl[i]) { take(dl[i], left: true); i += 1; grew = true }
                if j < dr.count && overlap(g, dr[j]) { take(dr[j], left: false); j += 1; grew = true }
            }
            out.append(contentsOf: b[bEnd(at)..<bEnd(s)])
            at = e
            let baseText = Array(b[bEnd(s)..<bEnd(e)])
            func version(_ g: [TokenHunk], _ xt: [Range<Int>], _ x: [UInt16]) -> [UInt16] {
                guard !g.isEmpty else { return baseText }
                var v: [UInt16] = []
                var k = s
                for h in g {
                    v.append(contentsOf: b[bEnd(k)..<bEnd(h.s)])
                    v.append(contentsOf: units(h, bt, xt, x, b.count).2)
                    k = h.e
                }
                v.append(contentsOf: b[bEnd(k)..<bEnd(e)])
                return v
            }
            let lv = version(gl, lt, l), rv = version(gr, rt, r)
            if gl.isEmpty { out.append(contentsOf: rv) }
            else if gr.isEmpty { out.append(contentsOf: lv) }
            else if lv == rv { out.append(contentsOf: lv) }
            else { out.append(contentsOf: mergeChars(baseText, lv, rv)) }
        }
        out.append(contentsOf: b[bEnd(at)...])
        return out
    }

    /// Hunks of a token diff: base tokens [s, e) became other tokens [xs, xe).
    struct TokenHunk { var s: Int; var e: Int; var xs: Int; var xe: Int }

    private static func overlap(_ g: TokenHunk, _ h: TokenHunk) -> Bool {
        overlap(Hunk(s: g.s, e: g.e, text: []), Hunk(s: h.s, e: h.e, text: []))
    }

    /// Inside one colliding place: diff3 on characters (surrogate pairs kept whole); if that still collides, both
    /// line versions stay, this device's first.
    static func mergeChars(_ b: [UInt16], _ l: [UInt16], _ r: [UInt16]) -> [UInt16] {
        let limit = 20_000
        guard b.count + l.count + r.count <= limit * 3 else { return bothVersions(b, l, r) }
        let (bt, bi) = scalars(b), (lt, li) = scalars(l), (rt, ri) = scalars(r)
        guard let dl = tokenHunks(bi, li), let dr = tokenHunks(bi, ri) else { return bothVersions(b, l, r) }
        var hunks: [Hunk] = []
        func unit(_ t: [Range<Int>], _ k: Int, _ count: Int) -> Int { k < t.count ? t[k].lowerBound : count }
        for h in dl { hunks.append(Hunk(s: unit(bt, h.s, b.count), e: unit(bt, h.e, b.count), text: Array(l[unit(lt, h.xs, l.count)..<unit(lt, h.xe, l.count)]))) }
        var right: [Hunk] = []
        for h in dr { right.append(Hunk(s: unit(bt, h.s, b.count), e: unit(bt, h.e, b.count), text: Array(r[unit(rt, h.xs, r.count)..<unit(rt, h.xe, r.count)]))) }
        for a in hunks { for c in right where strictOverlap(a, c) && !(a.s == c.s && a.e == c.e && a.text == c.text) { return bothVersions(b, l, r) } }
        // Identical changes on both sides count once; at one place this device's insertion comes first (a stable sort
        // keeps the local hunks ahead).
        let all = (hunks + right.filter { c in !hunks.contains { $0.s == c.s && $0.e == c.e && $0.text == c.text } })
            .enumerated().sorted { ($0.element.s, $0.element.e, $0.offset) < ($1.element.s, $1.element.e, $1.offset) }.map(\.element)
        return b.withUnsafeBufferPointer { apply(all, to: $0) }
    }

    /// Both versions of a place both sides changed: this device's, then the other's, a line break between them unless
    /// one is there already. Deleted on one side and changed on the other: the changed text stays.
    static func bothVersions(_ b: [UInt16], _ l: [UInt16], _ r: [UInt16]) -> [UInt16] {
        if l == b || l.isEmpty { return r }
        if r == b || r.isEmpty { return l }
        if l == r { return l }
        // Two insertions at one place: one after the other, as typed.
        if b.isEmpty { return l + r }
        var out = l
        if out.last != 0x0A && r.first != 0x0A { out.append(0x0A) }
        return out + r
    }

    /// Lines with their line break, as ranges.
    static func lines(_ u: [UInt16]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var s = 0
        for (i, c) in u.enumerated() where c == 0x0A { out.append(s..<(i + 1)); s = i + 1 }
        if s < u.count { out.append(s..<u.count) }
        return out
    }

    /// Unicode scalars as tokens, with their unit ranges.
    static func scalars(_ u: [UInt16]) -> ([Range<Int>], [Int]) {
        var ranges: [Range<Int>] = [], ids: [Int] = []
        var i = 0
        while i < u.count {
            if Diff.isHigh(u[i]) && i + 1 < u.count && Diff.isLow(u[i + 1]) {
                ranges.append(i..<(i + 2)); ids.append(0x10000 + (Int(u[i]) - 0xD800) << 10 + (Int(u[i + 1]) - 0xDC00)); i += 2
            } else {
                ranges.append(i..<(i + 1)); ids.append(Int(u[i])); i += 1
            }
        }
        return (ranges, ids)
    }

    /// Myers' O(ND) diff between token lists, as hunks; nil when the lists differ in more than `maxD` tokens (the caller
    /// then keeps both versions rather than spend seconds).
    static func tokenHunks(_ a: [Int], _ b: [Int], maxD: Int = 2000) -> [TokenHunk]? {
        // Common ends first: the diff runs on the middle only.
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let A = Array(a[p..<(a.count - s)]), Bt = Array(b[p..<(b.count - s)])
        let n = A.count, m = Bt.count
        if n == 0 && m == 0 { return [] }
        if n == 0 || m == 0 { return [TokenHunk(s: p, e: p + n, xs: p, xe: p + m)] }
        let total = n + m
        let dMax = min(total, maxD)
        // Myers keeps, for every d, the furthest x on diagonals -d...d; only that band is stored (d² in all).
        let off = total + 1
        var v = [Int](repeating: 0, count: 2 * total + 3)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...dMax {
            trace.append(Array(v[(off - d - 1)...(off + d + 1)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) { x = v[off + k + 1] } else { x = v[off + k - 1] + 1 }
                var y = x - k
                while x < n && y < m && A[x] == Bt[y] { x += 1; y += 1 }
                v[off + k] = x
                if x >= n && y >= m { found = true; break outer }
                k += 2
            }
        }
        guard found else { return nil }
        // Walk back to the edit script, collecting changed stretches.
        var x = n, y = m
        var marks: [(Int, Int, Int, Int)] = []   // (aFrom, aTo, bFrom, bTo) of a single step
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let band = trace[d]
            func at(_ k: Int) -> Int { band[k + d + 1] }
            let k = x - y
            let prevK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1
            let prevX = d == 0 ? 0 : at(prevK)
            let prevY = prevX - prevK
            while x > prevX && y > prevY { x -= 1; y -= 1 }
            if d > 0 { marks.append((prevX, x, prevY, y)) }
            x = prevX; y = prevY
        }
        // Each step is one insertion or deletion; join neighbours into hunks.
        var hunks: [TokenHunk] = []
        for (ax, ax2, by, by2) in marks.reversed() {
            let h = TokenHunk(s: p + ax, e: p + ax2, xs: p + by, xe: p + by2)
            if var last = hunks.last, last.e == h.s, last.xe == h.xs {
                last.e = h.e; last.xe = h.xe; hunks[hunks.count - 1] = last
            } else {
                hunks.append(h)
            }
        }
        return hunks
    }
}

/// A random-access collection of units as one buffer (arrays and buffer slices alike).
private struct UnsafeBufferPointerBox<C: RandomAccessCollection> where C.Element == UInt16, C.Index == Int {
    let c: C
    init(_ c: C) { self.c = c }
    func with<T>(_ body: (UnsafeBufferPointer<UInt16>) -> T) -> T {
        if let r = c.withContiguousStorageIfAvailable(body) { return r }
        return Array(c).withUnsafeBufferPointer(body)
    }
}
