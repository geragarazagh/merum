// The editor: one NSTextView per note on TextKit 1 with non-contiguous layout (AGENTS.md, «Measured»: it scrolls two to
// ten times faster than TextKit 2 and needs a third of its memory on a big text). Each view is built around an
// explicit NSLayoutManager attached to the note's own NSTextStorage, so the core's storage is the text the view edits
// and AppKit never builds TextKit 2 for it.
//
// Views live for the notes opened most recently (switching between them costs under a millisecond and keeps caret,
// selection, scroll and find bar as they were); an older one is taken apart, its layout manager detached from the
// storage, its selection and scroll kept to be put back when the note is opened again.
//
// The text views keep no undo of their own: every edit is reported to the core's History before it happens, and the
// window's undo manager is the History's (window.swift).
import AppKit

@MainActor final class NoteView {
    let scroll = NSScrollView()
    let text: NoteTextView
    let layout = NSLayoutManager()
    /// nil only for the empty editor shown when there are no notes.
    var note: Note?
    /// The text size (percent) the storage's attributes were last set for.
    var size = 0

    init(storage: NSTextStorage, editor: EditorController) {
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        text = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        text.editor = editor
        text.owner = self
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        // Plain text, nothing that reacts: no formatting, links, data detectors or attachments (AGENTS.md).
        text.isRichText = false
        text.importsGraphics = false
        text.allowsImageEditing = false
        text.usesFontPanel = false
        text.usesRuler = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.displaysLinkToolTips = false
        text.allowsUndo = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.allowsCharacterPickerTouchBarItem = true
        // Spelling as Apple Notes has it: checked while typing unless the person turned it off (Edit > Spelling and
        // Grammar); the substitutions are left to what macOS and the person set (Keyboard > Text Input, Edit >
        // Substitutions), NSTextView reads those itself.
        let d = UserDefaults.standard
        text.isContinuousSpellCheckingEnabled = d.object(forKey: "spellCheck") as? Bool ?? true
        text.isGrammarCheckingEnabled = d.bool(forKey: "grammarCheck")
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.delegate = editor

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = text
        scroll.autoresizingMask = [.width, .height]
        scroll.findBarPosition = .aboveContent
    }

    /// Takes the view apart: the storage keeps no layout manager of a note not on screen.
    func detach() {
        layout.textStorage?.removeLayoutManager(layout)
        scroll.removeFromSuperview()
    }
}

/// What an evicted view leaves behind, to put the caret and scroll back.
private struct Parked {
    var selection: [NSValue]
    var topCharacter: Int
}

@MainActor final class EditorController: NSViewController, NSTextViewDelegate {
    let library: Library
    /// Views kept, most recent last. Six W&P notes cost 5 MB each beyond the first (AGENTS.md, «Measured»).
    static let keep = 12
    private var views: [UUID: NoteView] = [:]
    private var recent: [UUID] = []
    private var parked: [UUID: Parked] = [:]
    private(set) var current: NoteView?
    private weak var previousShown: NoteView?
    /// While the empty editor turns into a note (the first keystroke with no notes).
    private var adopting: NoteView?
    var isAdopting: Bool { adopting != nil }
    /// Inside an edit the text view reports: its own selection changes then are not the person moving the caret.
    private var editing = 0
    private var storageObservers: [UUID: NSObjectProtocol] = [:]
    var onNoteCreated: ((Note) -> Void)?

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        v.autoresizesSubviews = true
        counter.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .center
        counter.lineBreakMode = .byTruncatingTail
        counter.frame = NSRect(x: 8, y: 4, width: v.bounds.width - 16, height: 15)
        counter.autoresizingMask = [.width, .maxYMargin]
        v.addSubview(counter)
        view = v
    }

    // MARK: the counts line under the text

    /// «24 characters · 4 words · ≈ 7 tokens», Copia's facts line, under the note. Counted off the main thread from a
    /// copy of the text (~1 ms per 10 M characters to take), half a second after typing pauses, so no keystroke ever
    /// waits for it; the last counts stay until the new ones are ready.
    let counter = NSTextField(labelWithString: "")
    static let counterHeight: CGFloat = 22
    private var counting: Task<Void, Never>?
    private var countGeneration = 0
    var onEdited: ((Note) -> Void)?

    func recount(after delay: Double) {
        counting?.cancel()
        countGeneration += 1
        let gen = countGeneration
        guard let n = current?.note else { counter.stringValue = ""; return }
        counting = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            guard !Task.isCancelled, let self, gen == self.countGeneration else { return }
            guard let f = await Facts.of(n.textSnapshot), !Task.isCancelled, gen == self.countGeneration,
                  self.current?.note === n else { return }
            self.counter.stringValue = f.line
        }
    }

    /// The text's area: the editor less the counts line.
    private var textFrame: NSRect {
        var r = view.bounds
        r.origin.y += Self.counterHeight
        r.size.height -= Self.counterHeight
        return r
    }

    var textView: NoteTextView? { current?.text }

    // MARK: text attributes

    static let baseSize: CGFloat = NSFont.systemFontSize   // 13 pt at 100 %, as Apple Notes' body

    var font: NSFont { NSFont.systemFont(ofSize: (Self.baseSize * CGFloat(library.textSize) / 100).rounded(.toNearestOrEven)) }
    var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.textColor] }

    /// Every note's storage gets the one font and colour on the characters an edit brings in (typing carries them;
    /// the core's undo and another device's text come as plain strings, and into an empty storage with none at all).
    func observeStorages() {
        let ids = Set(library.notes.map(\.id))
        for (id, o) in storageObservers where !ids.contains(id) {
            NotificationCenter.default.removeObserver(o); storageObservers[id] = nil
        }
        for n in library.notes where storageObservers[n.id] == nil {
            storageObservers[n.id] = NotificationCenter.default.addObserver(
                forName: NSTextStorage.willProcessEditingNotification, object: n.storage, queue: nil) { [weak self] note in
                guard let s = note.object as? NSTextStorage, s.editedMask.contains(.editedCharacters), s.editedRange.length > 0 else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    s.setAttributes(self.attributes, range: s.editedRange)
                }
            }
        }
    }

    /// The whole text in the current size; for a view that last showed another size.
    private func applySize(_ v: NoteView) {
        guard v.size != library.textSize else { return }
        let s = v.layout.textStorage!
        let a = attributes
        // Keep the first visible character at the top: the text rewraps under the reader's eye, the place stays.
        let top = v.size == 0 ? nil : topCharacter(v)
        if s.length > 0 {
            s.beginEditing()
            s.setAttributes(a, range: NSRange(location: 0, length: s.length))
            s.endEditing()
        }
        v.text.typingAttributes = a
        v.text.font = a[.font] as? NSFont
        v.size = library.textSize
        if let top { scroll(v, toCharacter: top) }
    }

    /// The spelling service loads a language's dictionaries the first time it meets that language, and NSTextView asks
    /// it on the main thread as the person types: measured, the first key in a note mixing Russian and French (War and
    /// Peace's first page) waited 0.4 s for it in a test machine. Asked here once, in the background, for the beginning
    /// of each note opened, the loading is done before the first key.
    private var warmed: Set<UUID> = []
    func warmSpelling(_ note: Note) {
        guard current?.text.isContinuousSpellCheckingEnabled == true, warmed.insert(note.id).inserted else { return }
        let s = note.storage.mutableString
        let r = s.paragraphRange(for: NSRange(location: 0, length: min(s.length, 4000)))
        let sample = s.substring(with: NSRange(location: r.location, length: min(r.length, 20000)))
        guard !sample.isEmpty else { return }
        NSSpellChecker.shared.requestChecking(of: sample, range: NSRange(location: 0, length: (sample as NSString).length),
                                              types: NSTextCheckingAllSystemTypes, options: nil, inSpellDocumentWithTag: 0) { _, _, _, _ in }
    }

    /// At launch: the dictionaries of every language the person set up, loaded in the background, so the first word
    /// typed in another of them does not wait (the 0.4 s above, per language, measured in a test machine).
    static func warmLanguages() {
        let sc = NSSpellChecker.shared
        for lang in sc.userPreferredLanguages {
            sc.requestChecking(of: "a", range: NSRange(location: 0, length: 1), types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                               options: [.orthography: NSOrthography.defaultOrthography(forLanguage: lang)],
                               inSpellDocumentWithTag: 0) { _, _, _, _ in }
        }
    }

    func textSizeChanged() {
        if let c = current { applySize(c) }
    }

    private func topCharacter(_ v: NoteView) -> Int {
        let visible = v.scroll.contentView.bounds
        guard v.layout.textStorage?.length ?? 0 > 0 else { return 0 }
        let origin = v.text.textContainerOrigin
        let p = NSPoint(x: visible.minX - origin.x + 1, y: visible.minY - origin.y + 1)
        let g = v.layout.glyphIndex(for: p, in: v.text.textContainer!)
        return v.layout.characterIndexForGlyph(at: g)
    }

    private func scroll(_ v: NoteView, toCharacter c: Int) {
        let length = v.layout.textStorage?.length ?? 0
        guard length > 0 else { return }
        let g = v.layout.glyphIndexForCharacter(at: min(c, length - 1))
        let r = v.layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let y = r.minY + v.text.textContainerOrigin.y
        let clip = v.scroll.contentView
        // Content insets: the toolbar over the text on a full-size content view.
        let inset = v.scroll.contentInsets.top
        clip.scroll(to: NSPoint(x: 0, y: max(-inset, y - inset)))
        v.scroll.reflectScrolledClipView(clip)
    }

    // MARK: showing a note

    /// Shows the note (nil: the empty editor of a library with no notes). `focus` puts the caret in it.
    func show(_ note: Note?, focus: Bool) {
        guard isViewLoaded else { return }
        let v: NoteView
        if let note {
            if let a = adopting {
                // The empty editor becomes this new note: same view, the note's storage under it.
                adopting = nil
                a.layout.replaceTextStorage(note.storage)
                a.note = note
                views[note.id] = a
                v = a
            } else if let have = views[note.id], have.layout.textStorage === note.storage {
                v = have
            } else {
                views[note.id]?.detach()
                // One layout manager per storage, ever: a view left over (the note was deleted while open and came back
                // by ⌘Z) would otherwise lay the same text out again on every edit and resize, one more time per
                // delete-and-undo (measured: one more after each ⌘A ⌘⌫ ⌘Z).
                for lm in note.storage.layoutManagers { note.storage.removeLayoutManager(lm) }
                v = NoteView(storage: note.storage, editor: self)
                v.note = note
                views[note.id] = v
            }
            recent.removeAll { $0 == note.id }
            recent.append(note.id)
        } else {
            if let c = current, c.note == nil { v = c } else {
                v = NoteView(storage: NSTextStorage(), editor: self)
            }
        }
        let wasFocused = current.map { view.window?.firstResponder === $0.text } ?? false
        if current !== v {
            // The note left goes out of the window, not just out of sight: a hidden view still follows every live
            // resize, and a big note's text rewrapped on each frame of it (his 1 M-character paste, 2026-11-25).
            current?.scroll.removeFromSuperview()
            // A view no longer kept (its note was deleted while it was open, or it is the empty editor) is taken apart.
            if let c = current, c !== v, c.note == nil || !views.values.contains(where: { $0 === c }) { c.detach() }
            if v.scroll.superview !== view {
                v.scroll.frame = textFrame
                view.addSubview(v.scroll)
            }
            current = v
        }
        applySize(v)
        if let note, let p = parked.removeValue(forKey: note.id) {
            let length = note.storage.length
            let sel = p.selection.map { $0.rangeValue }.filter { NSMaxRange($0) <= length }
            if !sel.isEmpty { v.text.selectedRanges = sel.map { NSValue(range: $0) } }
            scroll(v, toCharacter: min(p.topCharacter, max(0, length - 1)))
        }
        if focus || wasFocused { view.window?.makeFirstResponder(v.text) }
        if let note { warmSpelling(note) }
        if current !== previousShown { previousShown = current; counter.stringValue = ""; recount(after: 0) }
        evict()
    }

    private func evict() {
        while recent.count > Self.keep {
            let id = recent.removeFirst()
            guard let v = views.removeValue(forKey: id), v !== current else { continue }
            parked[id] = Parked(selection: v.text.selectedRanges, topCharacter: topCharacter(v))
            v.detach()
        }
    }

    /// A note that is gone: its view goes with it.
    func forget(_ ids: Set<UUID>) {
        for id in ids {
            if let v = views.removeValue(forKey: id), v !== current { v.detach() }
            parked[id] = nil
            recent.removeAll { $0 == id }
        }
    }

    /// Where the caret is, for the next launch.
    var caret: NSRange? { current?.note == nil ? nil : current?.text.selectedRange() }

    func select(_ range: NSRange) {
        guard let t = current?.text, NSMaxRange(range) <= (t.textStorage?.length ?? 0) else { return }
        t.setSelectedRange(range)
        t.scrollRangeToVisible(range)
    }

    // MARK: edits, reported to the History

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
        report(textView, [range], [string ?? ""])
    }

    func textView(_ textView: NSTextView, shouldChangeTextInRanges ranges: [NSValue], replacementStrings strings: [String]?) -> Bool {
        report(textView, ranges.map(\.rangeValue), strings ?? Array(repeating: "", count: ranges.count))
    }

    private func report(_ tv: NSTextView, _ ranges: [NSRange], _ strings: [String]) -> Bool {
        guard let t = tv as? NoteTextView, let v = t.owner else { return true }
        // Attribute-only changes (none here, the text is plain) carry no string.
        guard strings.count == ranges.count else { return true }
        if v.note == nil {
            // No notes: the first edit makes one and this view becomes it (show(), «adopting»): the note's storage goes
            // under the view. The edit NSTextView was about to make would land in the storage it held before, so it is
            // refused and made again, now into the note.
            adopting = v
            let n = library.ensureNote()
            if adopting != nil { show(n, focus: true) }
            onNoteCreated?(n)
            if ranges.count == 1, NSMaxRange(ranges[0]) <= n.length {
                replace(ranges[0], with: strings[0], in: t, kind: t.editKind ?? .typing)
            }
            return false
        }
        guard let note = v.note else { return true }
        editing += 1
        DispatchQueue.main.async { [weak self] in self?.editing = 0 }
        if ranges.count == 1 {
            library.history.willReplace(in: note, range: ranges[0], with: strings[0], as: t.editKind ?? .typing)
        } else {
            // Several ranges at once: Replace All in the find bar, or typing at several carets. NSTextView changes them
            // from the last to the first; reported in that order, each step's range holds when it is undone, and the
            // run loop's undo group makes them one ⌘Z.
            let column = Set(strings).count == 1 && (strings.first.map { ($0 as NSString).length <= 1 } ?? true)
            let kind: History.Kind = t.editKind ?? (column ? .named("Typing") : .named("Replace All"))
            for (r, s) in zip(ranges, strings).sorted(by: { $0.0.location > $1.0.location }) {
                library.history.willReplace(in: note, range: r, with: s, as: kind)
            }
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        editing = 0
        recount(after: 0.5)
        if let n = (notification.object as? NoteTextView)?.owner?.note { onEdited?(n) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard editing == 0, let t = notification.object as? NSTextView, !t.hasMarkedText() else { return }
        library.history.breakTyping()
    }

    // Edit > Spelling and Grammar: the person's choice is kept for every note and the next launch.
    func textView(_ textView: NSTextView, willCheckTextIn range: NSRange, options: [NSSpellChecker.OptionKey: Any] = [:],
                  types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>) -> [NSSpellChecker.OptionKey: Any] {
        // No links, no data detectors, whatever the system's defaults are.
        checkingTypes.pointee &= ~(NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.address.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.transitInformation.rawValue)
        return options
    }

    func spellingChanged(_ from: NSTextView) {
        let d = UserDefaults.standard
        d.set(from.isContinuousSpellCheckingEnabled, forKey: "spellCheck")
        d.set(from.isGrammarCheckingEnabled, forKey: "grammarCheck")
        for v in views.values where v.text !== from {
            v.text.isContinuousSpellCheckingEnabled = from.isContinuousSpellCheckingEnabled
            v.text.isGrammarCheckingEnabled = from.isGrammarCheckingEnabled
        }
    }

    // MARK: paste and drop, through the core

    /// Everything put into a note becomes text (the core's Paste): files as their paths, rich text as its plain string,
    /// a picture with no file as its recognised text. A picture is read on another thread (up to a few seconds, ~30 s
    /// the very first time); its text goes where the caret was when it was pasted, into that note even if another one
    /// is shown by then. A picture with no text, or a pasteboard with nothing that reads as text: a beep.
    func insert(from pb: NSPasteboard, into t: NoteTextView, kind: History.Kind) -> Bool {
        guard let content = Paste.content(of: pb) else { NSSound.beep(); return false }
        switch content {
        case .text(let s):
            replace(t.selectedRange(), with: s, in: t, kind: kind)
        case .image:
            // The core's pending paste: its place follows the edits made meanwhile, the note is not dropped as empty
            // while it waits, the text lands as one «Paste» step and the caret stays where the person left it.
            var note = t.owner?.note
            if note == nil, let v = t.owner {
                adopting = v
                let n = library.ensureNote()
                if adopting != nil { show(n, focus: true) }
                onNoteCreated?(n)
                note = n
            }
            guard let note else { return false }
            let range = t.selectedRange()
            Task { @MainActor [library] in
                if await library.paste(content, into: note, replacing: range) == nil { NSSound.beep() }
            }
        }
        return true
    }

    func replace(_ range: NSRange, with string: String, in t: NoteTextView, kind: History.Kind) {
        t.editKind = kind
        defer { t.editKind = nil }
        guard t.shouldChangeText(in: range, replacementString: string) else { return }
        t.textStorage?.replaceCharacters(in: range, with: string)
        t.didChangeText()
        let end = NSRange(location: range.location + (string as NSString).length, length: 0)
        // The caret after the inserted text is part of the edit, not the person moving it: a typing run goes on.
        editing += 1
        t.setSelectedRange(end)
        editing -= 1
        t.scrollRangeToVisible(end)
    }
}

/// The text view of one note: Edit's commands as any Mac text field has them, with paste and drop going through the
/// core's Paste and the kind of each edit told to the History («Undo Paste», «Undo Cut»).
final class NoteTextView: NSTextView {
    weak var editor: EditorController?
    weak var owner: NoteView?
    var editKind: History.Kind?

    override func paste(_ sender: Any?) { _ = editor?.insert(from: Clipboard.board, into: self, kind: .paste) }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    // Copy and Cut put the selection on the clipboard as plain text (several selected ranges joined by line breaks),
    // on the clipboard Clipboard.board names.
    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 || selectedRanges.count > 1 else { return }
        let s = string as NSString
        let text = selectedRanges.map { s.substring(with: $0.rangeValue) }.joined(separator: "\n")
        Clipboard.board.clearContents()
        Clipboard.board.setString(text, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 || selectedRanges.count > 1 else { return }
        copy(sender)
        editKind = .cut
        super.delete(sender)
        editKind = nil
    }

    override func delete(_ sender: Any?) {
        editKind = .delete
        super.delete(sender)
        editKind = nil
    }

    /// What paste, drop and Services may bring: every type the core's Paste turns into text.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { Self.readable }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Self.readable }
    static let readable: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .rtfd, .rtf, .html, .pdf, .png, .tiff,
        .init("public.jpeg"), .init("public.heic"), .init("com.apple.webarchive"), .color, .init("public.utf8-plain-text")]

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) || item.action == #selector(pasteAsRichText(_:)) {
            // Paste turns almost anything into text; reading it here would decode a picture at every menu check.
            return isEditable && !(Clipboard.board.types ?? []).isEmpty
        }
        return super.validateMenuItem(item)
    }

    /// Drops (and Services that return text) land here once NSTextView has put the selection where the text goes.
    /// A drag inside the same note is a move; NSTextView deletes the source itself.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let inside = (NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .leftMouseDragged) && pboard.name == .drag
        return editor?.insert(from: pboard, into: self, kind: inside ? .named("Drag") : .paste) ?? false
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        readSelection(from: pboard, type: .string)
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        editor?.spellingChanged(self)
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender)
        editor?.spellingChanged(self)
    }
}
