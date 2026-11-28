// Whatever is pasted or dropped into a note becomes text («an ode to text»):
// - files (copied in Finder or Files, dragged): their full paths, one per line, never their contents or icons;
// - text: as it is; rich text (RTF, RTFD, HTML, web archives): its plain string, attachments left out;
// - a link that is not a file: its address;
// - a picture with no file behind it (a screenshot straight to the clipboard, a copied image): the text in it, read
//   by Vision on the device in every language Vision has (Recognition); a PDF: its text, else the text read off its
//   first page's picture;
// - anything else: the first of its forms that reads as text (a type that conforms to public.text, or data that is
//   valid UTF-8), a colour as its hex.
// The order matters where one copy carries several forms: Finder puts a file's name beside its URL (the path wins);
// Numbers and Pages put a picture beside their text (the text wins); a copied web image carries its address (the
// picture's text wins).
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import PDFKit
#else
import UIKit
import PDFKit
#endif

enum Paste {
    /// What a pasteboard holds, read at once.
    enum Content: Equatable {
        case text(String)
        /// A picture to read: `Paste.recognize` gives its text (Vision takes from a fraction of a second to a few
        /// seconds, and ~30 s the very first time while it prepares its model).
        case image(CGImage)
        static func == (a: Content, b: Content) -> Bool {
            switch (a, b) {
            case let (.text(x), .text(y)): x == y
            case let (.image(x), .image(y)): x === y
            default: false
            }
        }
    }

    /// The text of a picture; "" when it has none (the UI then beeps: there is nothing to put in). Calls for the same
    /// picture while it is being read wait for that one reading instead of starting their own (see `lastPicture`).
    static func recognize(_ image: CGImage) async -> String {
        await reads.text(of: image)
    }

    /// One reading per picture at a time. Why: ⌘V held down on a copied picture made one Vision reading per key repeat,
    /// each with its own decoded and upscaled copies, all waiting at Recognition's gate; in a test machine 205 ⌘V of
    /// one 1016 x 493 picture took the app from 190 MB to 2.6 GB and paged the main thread into 3 s stalls (stress
    /// matrix 2026-11-27, macOS 27). The pastes still each get the text, in order.
    private actor Reads {
        private var running: [ObjectIdentifier: (image: CGImage, task: Task<String, Never>)] = [:]
        func text(of image: CGImage) async -> String {
            let id = ObjectIdentifier(image)   // the image is held in `running` while its id is a key: no reuse
            if let r = running[id] { return await r.task.value }
            let task = Task.detached { await Recognition.text(of: image) }
            running[id] = (image, task)
            let text = await task.value
            running[id] = nil
            return text
        }
    }
    private static let reads = Reads()

    /// The picture last read off a pasteboard, by the pasteboard's name and change count, so repeated pastes of one
    /// copy decode it once and hand `recognize` the same CGImage (the coalescing above goes by identity). Held 30 s at
    /// most, then let go: a big screenshot is not kept in memory for as long as it stays on the clipboard.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var stamp = ""
        private var image: CGImage?
        func get(_ k: String) -> CGImage? { lock.lock(); defer { lock.unlock() }; return k == stamp ? image : nil }
        func set(_ k: String, _ i: CGImage) {
            lock.lock(); stamp = k; image = i; lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                lock.lock(); if stamp == k { stamp = ""; image = nil }; lock.unlock()
            }
        }
    }
    private static let lastPicture = Memo()

    /// `read` through `lastPicture`: only a picture is remembered (text is read again: cheap, and never held).
    private static func remembered(_ key: String, _ read: () -> Content?) -> Content? {
        if let i = lastPicture.get(key) { return .image(i) }
        let c = read()
        if case .image(let i)? = c { lastPicture.set(key, i) }
        return c
    }

    /// Everything in one call: the text, recognising a picture when that is what there is. nil: the pasteboard is
    /// empty or holds nothing that reads as text.
    #if os(macOS)
    static func text(from pasteboard: NSPasteboard) async -> String? {
        switch content(of: pasteboard) {
        case .text(let s): return s
        case .image(let i): return await recognize(i)
        case nil: return nil
        }
    }
    #else
    static func text(from pasteboard: UIPasteboard) async -> String? {
        switch content(of: pasteboard) {
        case .text(let s): return s
        case .image(let i): return await recognize(i)
        case nil: return nil
        }
    }
    #endif

    #if os(macOS)
    /// The form of the pasteboard's content that becomes text (see the top of this file for the order).
    static func content(of pb: NSPasteboard) -> Content? {
        remembered("\(pb.name.rawValue)#\(pb.changeCount)") { read(pb) }
    }

    private static func read(_ pb: NSPasteboard) -> Content? {
        let types = Set(pb.types ?? [])
        // Files: every item that is a file URL.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .text(paths(urls))
        }
        if let s = pb.string(forType: .string) { return .text(s) }
        for t in [NSPasteboard.PasteboardType.rtfd, .rtf, .html, NSPasteboard.PasteboardType("com.apple.webarchive")] where types.contains(t) {
            if let data = pb.data(forType: t), let s = plain(data, t.rawValue) { return .text(s) }
        }
        if types.contains(.pdf), let data = pb.data(forType: .pdf), let c = pdf(data) { return c }
        if let image = picture(pb) { return .image(image) }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return .text(urls.map(\.absoluteString).joined(separator: "\n"))
        }
        if let color = NSColor(from: pb) ?? (pb.readObjects(forClasses: [NSColor.self]) as? [NSColor])?.first { return .text(hex(color.cgColor)) }
        for item in pb.pasteboardItems ?? [] {
            for t in item.types {
                if let s = item.string(forType: t), conformsToText(t.rawValue) { return .text(s) }
            }
            for t in item.types {
                if let d = item.data(forType: t), let s = utf8(d) { return .text(s) }
            }
        }
        return nil
    }

    private static func picture(_ pb: NSPasteboard) -> CGImage? {
        guard NSImage.canInit(with: pb) else { return nil }
        // Raw bytes first: the picture at its own pixel size, not an icon-sized representation.
        for t in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let d = pb.data(forType: t), let i = cgImage(d) { return i }
        }
        if let image = NSImage(pasteboard: pb) {
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }
    #else
    static func content(of pb: UIPasteboard) -> Content? {
        remembered("\(pb.name.rawValue)#\(pb.changeCount)") { read(pb) }
    }

    private static func read(_ pb: UIPasteboard) -> Content? {
        // Files: items whose URL is a file.
        if pb.hasURLs, let urls = pb.urls, !urls.isEmpty, urls.allSatisfy(\.isFileURL) { return .text(paths(urls)) }
        if pb.hasStrings, let s = pb.strings, !s.isEmpty { return .text(s.joined(separator: "\n")) }
        for item in pb.items {
            for (type, value) in item {
                if let d = value as? Data, [UTType.rtfd, .rtf, .html, .webArchive].contains(where: { UTType(type)?.conforms(to: $0) == true }),
                   let s = plain(d, type) { return .text(s) }
            }
        }
        for item in pb.items {
            for (type, value) in item where UTType(type)?.conforms(to: .pdf) == true {
                if let d = value as? Data, let c = pdf(d) { return c }
            }
        }
        if pb.hasImages, let image = pb.image, let cg = image.cgImage ?? image.ciImage.flatMap({ CIContext().createCGImage($0, from: $0.extent) }) {
            return .image(cg)
        }
        for item in pb.items {
            for (type, value) in item where UTType(type)?.conforms(to: .image) == true {
                if let d = value as? Data, let i = cgImage(d) { return .image(i) }
            }
        }
        if pb.hasURLs, let urls = pb.urls, !urls.isEmpty {
            return .text(urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n"))
        }
        if pb.hasColors, let c = pb.color { return .text(hex(c.cgColor)) }
        for item in pb.items {
            for (type, value) in item {
                if let s = value as? String { return .text(s) }
                if let d = value as? Data, conformsToText(type) || utf8(d) != nil, let s = utf8(d) { return .text(s) }
            }
        }
        return nil
    }
    #endif

    // MARK: shared pieces

    /// Full paths, one per line, in the order they were copied.
    static func paths(_ urls: [URL]) -> String {
        urls.map { $0.standardizedFileURL.path }.joined(separator: "\n")
    }

    /// The plain string of rich text; attachments (U+FFFC) leave no mark. HTML and web archives are read by HTMLText,
    /// never by NSAttributedString's HTML import (WebKit, which may fetch what the page names); RTF and RTFD name
    /// nothing remote.
    static func plain(_ data: Data, _ type: String) -> String? {
        let ut = UTType(type)
        if type == "com.apple.webarchive" || ut?.conforms(to: .webArchive) == true { return HTMLText.webArchiveText(data) }
        if type == "public.html" || ut?.conforms(to: .html) == true { return HTMLText.text(data) }
        let docType: NSAttributedString.DocumentType
        if type == "com.apple.flat-rtfd" || ut?.conforms(to: .rtfd) == true || ut?.conforms(to: .flatRTFD) == true { docType = .rtfd }
        else if type == "public.rtf" || ut?.conforms(to: .rtf) == true { docType = .rtf }
        else { return nil }
        guard let a = try? NSAttributedString(data: data, options: [.documentType: docType], documentAttributes: nil) else { return nil }
        return a.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// A PDF's own text, or the picture of its first page to read when it has none (a scan).
    static func pdf(_ data: Data) -> Content? {
        guard let doc = PDFDocument(data: data) else { return nil }
        if let s = doc.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(s) }
        guard let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        // About 200 dpi: small print stays readable for Vision.
        let scale = min(200.0 / 72.0, 6000 / max(box.width, box.height, 1))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage().map { .image($0) }
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decoded now: a lazily decoded image may outlive its data.
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func utf8(_ d: Data) -> String? {
        guard !d.isEmpty, let s = String(data: d, encoding: .utf8), !s.contains("\0") else { return nil }
        return s
    }

    static func conformsToText(_ type: String) -> Bool { UTType(type)?.conforms(to: .text) == true }

    /// sRGB, «#RRGGBB» (with alpha «#RRGGBBAA» when not opaque).
    static func hex(_ c: CGColor) -> String {
        let srgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c
        let comps = srgb.components ?? [0, 0, 0, 1]
        let rgb = comps.count >= 3 ? Array(comps.prefix(3)) : [comps[0], comps[0], comps[0]]
        let a = comps.last ?? 1
        func b(_ v: CGFloat) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + rgb.map(b).joined() + (a < 1 ? b(a) : "")
    }
}

/// Where a paste that waits for its text will land: moved by every edit of the note made meanwhile (typing before it
/// pushes it on, typing at its place stays after it, as typed after the paste in time), kept by Library.
@MainActor final class PendingPaste {
    let note: Note
    private(set) var range: NSRange

    init(note: Note, range: NSRange) {
        self.note = note
        self.range = range
    }

    /// An edit that is done: `edited` is the new text's range, `delta` the change in length.
    func shift(_ edited: NSRange, _ delta: Int) {
        let start = edited.location, oldEnd = edited.location + edited.length - delta
        let end = range.location + range.length
        if start >= end && !(start == range.location && range.length == 0 && oldEnd > start) {
            // After the place, or an insertion right at a caret: untouched.
            return
        }
        if oldEnd <= range.location {
            range.location += delta   // wholly before
        } else {
            // Into the selection the paste was to replace, or over the caret: the paste goes in before the edit and
            // removes nothing.
            range = NSRange(location: min(start, range.location), length: 0)
        }
    }
}
