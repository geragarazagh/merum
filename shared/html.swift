// Pasted HTML (and a web archive's page) to plain text, by hand. NSAttributedString's HTML import runs WebKit, which
// may fetch the page's pictures, style sheets and fonts from the network (on iPhone it has been seen to load images
// synchronously): a network call this app must never make, and a tracker pixel would learn what was pasted and when.
// Only the text is wanted, so the markup is read here and nothing it names is ever requested.
import Foundation

enum HTMLText {
    /// Plain text of an HTML document: paragraphs and other blocks on lines of their own, <br> a line break, list
    /// items «• » (or «1. » in a numbered list), table cells by tabs, whitespace collapsed as a browser does except
    /// inside <pre>; script, style, head and comments dropped; character references decoded.
    static func text(_ data: Data) -> String {
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        return text(html)
    }

    /// A web archive (com.apple.webarchive) holds its page in WebMainResource; only that page's text is taken.
    static func webArchiveText(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any], let page = main["WebResourceData"] as? Data else { return nil }
        return text(page)
    }

    private static let blocks: Set<String> = ["p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table",
        "blockquote", "section", "article", "header", "footer", "pre", "hr", "dt", "dd", "dl", "figure", "figcaption",
        "address", "nav", "aside", "main", "form", "fieldset", "details", "summary", "caption", "thead", "tbody", "tfoot", "center"]
    private static let dropped: Set<String> = ["script", "style", "head", "title", "template", "noscript", "svg", "math", "object", "iframe", "select"]

    static func text(_ html: String) -> String {
        var out = ""
        var pre = 0
        var skip: String?            // inside a dropped element: its name
        var lists: [Int?] = []       // nil: bulleted; n: the next number
        var cellInRow = 0
        let s = Array(html.unicodeScalars)
        var i = 0
        var pendingSpace = false
        func lineBreak() {
            pendingSpace = false
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        }
        func emit(_ t: String) {
            if pendingSpace && !out.isEmpty && !out.hasSuffix("\n") && !out.hasSuffix(" ") && !out.hasSuffix("\t") { out += " " }
            pendingSpace = false
            out += t
        }
        var textRun = ""
        func flushText() {
            guard !textRun.isEmpty else { return }
            let t = decode(textRun)
            textRun = ""
            if pre > 0 { emit(t); return }
            // Whitespace collapses to one space, and a space at a line's start goes.
            var word = ""
            for ch in t {
                if ch.isWhitespace && ch != "\u{00A0}" {
                    if !word.isEmpty { emit(word); word = "" }
                    pendingSpace = true
                } else {
                    word.append(ch == "\u{00A0}" ? " " : ch)
                }
            }
            if !word.isEmpty { emit(word) }
        }
        while i < s.count {
            if s[i] == "<" {
                // A comment.
                if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                    var j = i + 4
                    while j + 2 < s.count && !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                    i = j + 3; continue
                }
                // A tag: its name and whether it closes.
                var j = i + 1
                var quote: Unicode.Scalar?
                while j < s.count {
                    if let q = quote { if s[j] == q { quote = nil } }
                    else if s[j] == "\"" || s[j] == "'" { quote = s[j] }
                    else if s[j] == ">" { break }
                    j += 1
                }
                let inner = String(String.UnicodeScalarView(s[(i + 1)..<min(j, s.count)]))
                i = j + 1
                let closing = inner.hasPrefix("/")
                let name = inner.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
                if let k = skip {
                    if closing && name == k { skip = nil }
                    continue
                }
                guard !name.isEmpty else { continue }   // <!DOCTYPE>, <?xml?>
                flushText()
                if dropped.contains(name) {
                    if !closing && !inner.hasSuffix("/") { skip = name }
                    continue
                }
                switch name {
                case "br": pendingSpace = false; out += "\n"
                case "pre": lineBreak(); pre += closing ? (pre > 0 ? -1 : 0) : 1
                case "ul": lineBreak(); if closing { _ = lists.popLast() } else { lists.append(nil) }
                case "ol":
                    lineBreak()
                    if closing { _ = lists.popLast() } else {
                        let start = attribute("start", in: inner).flatMap { Int($0) } ?? 1
                        lists.append(start)
                    }
                case "li":
                    lineBreak()
                    if !closing {
                        if let last = lists.last, let n = last { out += "\(n). "; lists[lists.count - 1] = n + 1 } else { out += "• " }
                    }
                case "tr": lineBreak(); cellInRow = 0
                case "td", "th":
                    if !closing { if cellInRow > 0 { out += "\t" }; cellInRow += 1; pendingSpace = false }
                default:
                    if blocks.contains(name) { lineBreak() }
                }
            } else {
                if skip == nil { textRun.unicodeScalars.append(s[i]) }
                i += 1
            }
        }
        flushText()
        // No empty lines at the ends, no trailing spaces on lines.
        let lines = out.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasSuffix(" ") { l.removeLast() }
            return l
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func attribute(_ key: String, in tag: String) -> String? {
        guard let r = tag.range(of: key + "=", options: .caseInsensitive) else { return nil }
        return String(tag[r.upperBound...].drop { $0 == "\"" || $0 == "'" }.prefix { $0.isNumber || $0 == "-" })
    }

    /// Character references: numeric ones and the named ones text on the web uses; an unknown name stays as written.
    static func decode(_ t: String) -> String {
        guard t.contains("&") else { return t }
        var out = ""
        var i = t.startIndex
        while i < t.endIndex {
            guard t[i] == "&", let semi = t[i...].prefix(40).firstIndex(of: ";") else { out.append(t[i]); i = t.index(after: i); continue }
            let name = t[t.index(after: i)..<semi]
            var value: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") { value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
            else if name.hasPrefix("#") { value = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
            else { value = named[String(name)] }
            if let value { out += value; i = t.index(after: semi) } else { out.append(t[i]); i = t.index(after: i) }
        }
        return out
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "shy": "", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−", "laquo": "«", "raquo": "»",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "lsaquo": "‹", "rsaquo": "›",
        "bull": "•", "middot": "·", "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
        "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³",
        "micro": "µ", "iexcl": "¡", "iquest": "¿", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "infin": "∞", "check": "✓", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è",
        "ecirc": "ê", "aacute": "á", "agrave": "à", "acirc": "â", "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ",
        "ccedil": "ç", "Eacute": "É", "oslash": "ø", "aring": "å", "aelig": "æ", "Oslash": "Ø", "Aring": "Å", "AElig": "Æ",
    ]
}
