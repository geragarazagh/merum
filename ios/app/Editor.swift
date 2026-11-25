// The editor: one UITextView per note, each built over the note's own NSTextStorage, the most recent ones kept.
//
// Why it is built this way (measured on an iPhone 15 Pro with «War and Peace», 3 M characters, and 10 M; AGENTS.md,
// «Measured (iPhone)»):
// - TextKit 1 with non-contiguous layout, through an explicit NSLayoutManager: TextKit 2 dropped scroll frames to
//   233 ms and keystrokes to 202 ms on 10 M, and spent up to 75 ms a keystroke after a note switch.
// - A view per note, never a storage swapped under one view: after a swap UITextView's `text` and `textStorage` still
//   answer for the old storage while layout and typing use the new one.
// - The view's typesetting language is pinned: UIKit compares the old and new trait with isEqualToString:, so the
//   default nil reads as a change on every trait change and walks the whole text's attributes again.
// - Paste, cut and undo write into the storage directly: UITextInput's replace(_:withText:) took 5.7 s to insert
//   3 M characters, the storage 46 ms.
import SwiftUI
import UIKit

/// Holds the text view of the note on screen; SwiftUI hosts this one view.
final class EditorContainer: UIView {
    private(set) var shown: NoteTextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The screen's margins (system minimum plus safe area) reach the text view, so text lines up with the title.
        preservesSuperviewLayoutMargins = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tv: NoteTextView) {
        guard shown !== tv else { return }
        shown?.removeFromSuperview()
        tv.frame = bounds
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(tv)
        shown = tv
    }
}

@MainActor final class Editors: NSObject, UITextViewDelegate, NSTextStorageDelegate {
    weak var model: Model?
    let library: Library
    let container = EditorContainer()
    /// The next note shown takes the keyboard: a note always opens ready to type, at launch and from the list alike
    /// (his decision 2026-11-25: «просто всегда открывать клавиатуру»); a swipe down on the text puts it away.
    var focusNext = false

    /// Views of the notes opened most recently, the newest last. Each keeps its layout, caret and scroll; a big note's
    /// layout costs memory (10 M characters scrolled through: ~240 MB), so only a few stay.
    private var views: [UUID: NoteTextView] = [:]
    private var order: [UUID] = []
    private let keep = 6

    /// The font each storage carries, so a note opened again is not re-attributed.
    private let applied = NSMapTable<NSTextStorage, NSNumber>.weakToStrongObjects()
    /// While the editor itself changes the text or selection: the selection change that follows is not the person's.
    private var editing = false
    /// An edit was reported to the History and its storage change has not arrived yet.
    private var reported = false

    /// The bar over the keyboard while typing, where Notes keeps its bottom bar then: a system toolbar, so New Note is
    /// a standard bar item at Apple's own size (a custom SwiftUI button there was smaller and shrank when pressed),
    /// and the counter centred between it and an invisible twin on the left.
    private(set) lazy var accessory: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 52))
        bar.autoresizingMask = [.flexibleWidth]
        bar.setBackgroundImage(UIImage(), forToolbarPosition: .any, barMetrics: .default)
        bar.setShadowImage(UIImage(), forToolbarPosition: .any)
        counterLabel.font = .preferredFont(forTextStyle: .caption1)
        counterLabel.adjustsFontForContentSizeCategory = true
        counterLabel.textColor = .secondaryLabel
        counterLabel.textAlignment = .center
        let counter = UIBarButtonItem(customView: counterLabel)
        counter.hidesSharedBackground = true
        let compose = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"),
                                      primaryAction: UIAction { [weak self] _ in self?.model?.compose() })
        compose.accessibilityLabel = "New Note"
        let twin = UIBarButtonItem(customView: UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44)))
        twin.hidesSharedBackground = true
        bar.items = [twin, .flexibleSpace(), counter, .flexibleSpace(), compose]
        return bar
    }()
    let counterLabel = UILabel()

    /// The counter's text in both bars, set in place (no relayout of the bar).
    func showFacts(_ text: String) {
        counterLabel.text = text
        counterLabel.sizeToFit()
    }

    init(model: Model) {
        self.model = model
        library = model.library
        super.init()
    }

    // MARK: fonts

    /// Dynamic Type's body size at the synced percentage, in San Francisco.
    var font: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .body).pointSize
        return UIFont.systemFont(ofSize: (base * CGFloat(library.textSize) / 100).rounded())
    }
    var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: UIColor.label] }

    private func attribute(_ st: NSTextStorage) {
        let f = font
        guard applied.object(forKey: st)?.doubleValue != Double(f.pointSize) else { return }
        applied.setObject(NSNumber(value: Double(f.pointSize)), forKey: st)
        guard st.length > 0 else { return }
        st.beginEditing()
        st.setAttributes([.font: f, .foregroundColor: UIColor.label], range: NSRange(location: 0, length: st.length))
        st.endEditing()
    }

    /// Text size or Dynamic Type changed: the views kept get the new font now, the others when they are opened.
    func applyTextSize() {
        let a = attributes
        for v in views.values {
            attribute(v.textStorage)
            v.typingAttributes = a
        }
    }

    // MARK: views

    func view(for note: Note) -> NoteTextView {
        if let v = views[note.id], v.note === note {
            order.removeAll { $0 == note.id }
            order.append(note.id)
            return v
        }
        let st = note.storage
        st.delegate = self
        attribute(st)
        let tc = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = true
        lm.addTextContainer(tc)
        st.addLayoutManager(lm)
        let tv = NoteTextView(frame: container.bounds, textContainer: tc)
        tv.note = note
        tv.editors = self
        tv.delegate = self
        tv.undoProxy.history = library.history.undoManager
        tv.undoProxy.textView = tv
        tv.typingAttributes = attributes
        tv.inputAccessoryView = accessory
        if let at = savedCaret(note), at <= st.length { tv.selectedRange = NSRange(location: at, length: 0) }
        views[note.id] = tv
        order.append(note.id)
        evict()
        return tv
    }

    private func evict() {
        while order.count > keep {
            let id = order.removeFirst()
            if let v = views.removeValue(forKey: id), v !== container.shown { drop(v) }
        }
    }

    private func drop(_ v: NoteTextView) {
        v.removeFromSuperview()
        v.textStorage.removeLayoutManager(v.layoutManager)
    }

    /// Notes that left the library lose their views (a deleted note's view would hold its layout for nothing).
    func dropViews(keeping ids: Set<UUID>) {
        for (id, v) in views where !ids.contains(id) && v.note !== model?.current {
            views[id] = nil
            order.removeAll { $0 == id }
            drop(v)
        }
    }

    /// Puts the current note's view on screen.
    func showCurrent() {
        guard let n = model?.current else { return }
        let tv = view(for: n)
        container.show(tv)
        // Taken the moment a push ends, so the keyboard rises from the bottom as in Notes (his recording: push, then
        // the keyboard up); taken during the push it slid in sideways after it. At once when nothing is moving.
        if focusNext, tv.window != nil {
            focusNext = false
            let vc = sequence(first: tv as UIResponder, next: \.next).compactMap { $0 as? UIViewController }.first
            if let tc = vc?.transitionCoordinator {
                // Not earlier: during the transition UIKit carries the keyboard in sideways with the view (tried at
                // the push's start and at its 0.35 s duration). Its completion (~0.53 s, the spring settled) gives
                // Notes' order: the push, then the keyboard rising, ~0.2 s after the push looks done (Notes: ~0.3 s).
                tc.animate(alongsideTransition: nil) { [weak tv] ctx in
                    if !ctx.isCancelled, tv?.window != nil { tv?.becomeFirstResponder() }
                }
            } else {
                tv.becomeFirstResponder()
            }
        }
    }

    // MARK: the caret, kept per note on this device

    private static let caretKey = "caret"
    /// Where each note's caret was, for the next launch (a view kept in memory remembers it by itself).
    func saveCarets() {
        var d = UserDefaults.standard.dictionary(forKey: Editors.caretKey) as? [String: Int] ?? [:]
        for (id, v) in views where library.note(id: id) != nil { d[id.uuidString] = v.selectedRange.location }
        let live = Set(library.notes.map(\.id.uuidString))
        d = d.filter { live.contains($0.key) }
        UserDefaults.standard.set(d, forKey: Editors.caretKey)
    }

    private func savedCaret(_ note: Note) -> Int? {
        (UserDefaults.standard.dictionary(forKey: Editors.caretKey) as? [String: Int])?[note.id.uuidString]
    }

    func endEditing() { container.shown?.resignFirstResponder() }

    /// The Undo button and its Redo: through the shown view's manager, so the keyboard hears of the change.
    func undo() { (container.shown?.undoManager ?? library.history.undoManager).undo() }
    func redo() { (container.shown?.undoManager ?? library.history.undoManager).redo() }

    func findInNote() {
        guard let tv = container.shown else { return }
        tv.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// The system share sheet with the note's text as it is now (plain text), grown out of the Share button as in
    /// Notes. Its source item is the navigation bar's own Share item (SwiftUI's toolbar buttons are bar button items
    /// there); a search of the window by label had found another view on a device and the sheet rose from the bottom.
    func share() {
        guard let tv = container.shown, let window = tv.window, let vc = window.rootViewController else { return }
        let text = tv.textStorage.mutableString.copy() as! String
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController, let item = Editors.shareItem(from: tv) { pop.sourceItem = item }
        // The keyboard goes down under the sheet and comes back when it closes, as in Notes (his frames 2026-11-25):
        // the text keeps first responder throughout.
        var top = sequence(first: tv as UIResponder, next: \.next).compactMap { $0 as? UIViewController }.first ?? vc
        while let p = top.presentedViewController { top = p }
        top.present(sheet, animated: true)
    }

    private static func shareItem(from view: UIView) -> UIBarButtonItem? {
        let vcs = sequence(first: view as UIResponder, next: \.next).compactMap { $0 as? UIViewController }
        for vc in vcs {
            for nav in [vc.navigationController, vc as? UINavigationController].compactMap({ $0 }) {
                for owner in [nav.topViewController, vc].compactMap({ $0 }) {
                    let ni = owner.navigationItem
                    let items = (ni.rightBarButtonItems ?? []) + ni.trailingItemGroups.flatMap(\.barButtonItems)
                    if let hit = items.first(where: { isShare($0) }) { return hit }
                }
            }
        }
        return nil
    }

    private static func isShare(_ item: UIBarButtonItem) -> Bool {
        item.title == "Share" || item.accessibilityLabel == "Share"
            || item.image?.accessibilityIdentifier == "square.and.arrow.up"
    }

    func select(_ range: NSRange, in note: Note) {
        let tv = view(for: note)
        guard NSMaxRange(range) <= note.storage.length else { return }
        // Undo selects what it brought back, as the Mac does, up to a size: with the keyboard up iOS word-counts any
        // selection it leaves (measured: redo of a 10 M paste 1.3 s, all of it that count), so a bigger restored text
        // gets the caret at its end instead.
        let range = range.length > 100_000 ? NSRange(location: NSMaxRange(range), length: 0) : range
        editing = true
        tv.selectedRange = range
        editing = false
        // After the view is in the window and laid out (a note just switched to).
        DispatchQueue.main.async { tv.scrollRangeToVisible(range) }
    }

    // MARK: edits, reported to the History

    private func note(of tv: UITextView) -> Note? {
        guard let t = tv as? NoteTextView, let n = t.note else { return nil }
        model?.adopt(n)
        return n
    }

    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let n = note(of: tv) else { return true }
        library.history.willReplace(in: n, range: range, with: text, as: .typing)
        reported = true
        holdSelection()
        return true
    }

    /// The selection change an edit makes by itself does not end the typing run; the person's own move does.
    private func holdSelection() {
        editing = true
        DispatchQueue.main.async { [weak self] in self?.editing = false }
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        guard !editing, tv.markedTextRange == nil else { return }
        library.history.breakTyping()
    }

    /// Paste, cut and the text of a picture: straight into the storage, one History step.
    func replace(_ range: NSRange, with string: String, in tv: NoteTextView, kind: History.Kind) {
        guard let n = note(of: tv), NSMaxRange(range) <= n.storage.length else { return }
        let length = (string as NSString).length
        guard range.length > 0 || length > 0 else { return }
        library.history.willReplace(in: n, range: range, with: string, as: kind)
        reported = true
        holdSelection()
        let st = n.storage
        tv.inputDelegate?.selectionWillChange(tv)
        tv.inputDelegate?.textWillChange(tv)
        st.beginEditing()
        st.replaceCharacters(in: range, with: string)
        if length > 0 { st.setAttributes(attributes, range: NSRange(location: range.location, length: length)) }
        st.endEditing()
        tv.selectedRange = NSRange(location: range.location + length, length: 0)
        tv.inputDelegate?.textDidChange(tv)
        tv.inputDelegate?.selectionDidChange(tv)
        tv.scrollRangeToVisible(tv.selectedRange)
    }

    // Every character change passes here. Text the core writes (undo, another device) takes the note's attributes;
    // an edit nobody reported (a path of UIKit's that skips the delegate) would leave the History's ranges wrong, so
    // that note's text steps are dropped instead: the text is always right, undo of that run is lost.
    nonisolated func textStorage(_ st: NSTextStorage, willProcessEditing mask: NSTextStorage.EditActions,
                                 range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            if range.length > 0, (st.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont) != font {
                st.setAttributes(attributes, range: range)
            }
            if reported { reported = false; return }
            guard library.applying == nil, let n = views.values.first(where: { $0.textStorage === st })?.note,
                  library.contains(n) else { return }
            library.history.dropText(of: n)
        }
    }

    // MARK: paste, copy, cut

    /// Everything pasted becomes text through the core: files as their paths, rich text as its plain string, a
    /// picture with no file as the text Vision reads in it (on another thread; it lands where the caret was).
    func paste(into tv: NoteTextView) {
        guard let content = Paste.content(of: UIPasteboard.general) else { return }
        switch content {
        case .text(let s):
            replace(tv.selectedRange, with: s, in: tv, kind: .paste)
        case .image(let image):
            // A picture is read by Vision (~0.4 s, a minute the first time); the core keeps the paste's place while
            // the person goes on typing or switches notes, and puts the text in as one «Paste».
            guard let note = tv.note else { return }
            let p = library.beginPaste(in: note, replacing: tv.selectedRange)
            Task { @MainActor [weak self] in
                let text = await Paste.recognize(image)
                guard let self else { return }
                self.reported = true   // the core reports this edit to the History itself
                self.library.finishPaste(p, with: text)
                self.reported = false
            }
        }
    }

    /// Plain text only: a styled copy of a huge selection costs seconds and carries a font nobody asked for.
    func copy(from tv: NoteTextView) {
        let r = tv.selectedRange
        guard r.length > 0 else { return }
        UIPasteboard.general.string = tv.textStorage.mutableString.substring(with: r)
    }

    func cut(from tv: NoteTextView) {
        let r = tv.selectedRange
        guard r.length > 0 else { return }
        copy(from: tv)
        replace(r, with: "", in: tv, kind: .cut)
    }

    /// ⌘+ ⌘− ⌘0 with a keyboard: the synced text size, one step.
    func stepTextSize(_ by: Int) {
        let sizes = Library.textSizes
        let i = sizes.firstIndex(of: library.textSize) ?? sizes.firstIndex(of: 100)!
        library.textSize = by == 0 ? 100 : sizes[max(0, min(sizes.count - 1, i + by))]
    }
}

/// A note's text view. Plain text, no detectors; its undo goes to the one History and it registers nothing itself.
final class NoteTextView: UITextView {
    var note: Note?
    weak var editors: Editors?
    let undoProxy = ForwardingUndoManager()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        dataDetectorTypes = []
        allowsEditingTextAttributes = false
        traitOverrides.typesettingLanguage = Locale.Language(identifier: "en")
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        isFindInteractionEnabled = true
        accessibilityLabel = "Note"
        preservesSuperviewLayoutMargins = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { undoProxy }


    // Text lines up with the navigation title: the system's minimum margin for the width class (16 pt compact,
    // 20 pt regular, as UIKit's systemMinimumLayoutMargins on iPhone) plus the safe area, less the line padding.
    // Computed here: SwiftUI's host views between the screen and this view do not pass layout margins down.
    override func layoutSubviews() {
        let margin: CGFloat = traitCollection.horizontalSizeClass == .regular ? 20 : 16
        let pad = textContainer.lineFragmentPadding
        let inset = UIEdgeInsets(top: 8, left: safeAreaInsets.left + margin - pad, bottom: 8,
                                 right: safeAreaInsets.right + margin - pad)
        if textContainerInset != inset { textContainerInset = inset }
        super.layoutSubviews()
    }

    override func paste(_ sender: Any?) { MainActor.assumeIsolated { editors?.paste(into: self) } }
    override func copy(_ sender: Any?) { MainActor.assumeIsolated { editors?.copy(from: self) } }
    override func cut(_ sender: Any?) { MainActor.assumeIsolated { editors?.cut(from: self) } }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Anything on the pasteboard becomes text, so Paste is offered for pictures and files too. Counting the items
        // does not read them, so iOS asks no permission here.
        if action == #selector(paste(_:)) { return isEditable && UIPasteboard.general.numberOfItems > 0 }
        if action == #selector(pasteAndMatchStyle(_:)) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Bigger", action: #selector(bigger), input: "+", modifierFlags: .command),
         UIKeyCommand(title: "Bigger", action: #selector(bigger), input: "=", modifierFlags: .command, attributes: .hidden),
         UIKeyCommand(title: "Smaller", action: #selector(smaller), input: "-", modifierFlags: .command),
         UIKeyCommand(title: "Actual Size", action: #selector(actualSize), input: "0", modifierFlags: .command)]
    }
    @objc private func bigger() { MainActor.assumeIsolated { editors?.stepTextSize(1) } }
    @objc private func smaller() { MainActor.assumeIsolated { editors?.stepTextSize(-1) } }
    @objc private func actualSize() { MainActor.assumeIsolated { editors?.stepTextSize(0) } }
}

/// What the text views and the window hand out as their undo manager. UIKit's own registrations (UITextView typing,
/// a text field in an alert) land here and are dropped; undo, redo and the questions the shake alert and the menus
/// ask go to the History's manager. The text view's keyboard is told around an undo, as UIKit does for its own.
final class ForwardingUndoManager: UndoManager {
    weak var history: UndoManager?
    weak var textView: UITextView?
    /// Registrations that came and were dropped (the test reads it).
    private(set) var dropped = 0

    override init() {
        super.init()
        groupsByEvent = false
        super.disableUndoRegistration()
    }

    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) { dropped += 1 }
    override func prepare(withInvocationTarget target: Any) -> Any { dropped += 1; return super.prepare(withInvocationTarget: target) }
    override var isUndoRegistrationEnabled: Bool { false }
    override func enableUndoRegistration() {}
    override func disableUndoRegistration() {}
    override func beginUndoGrouping() {}
    override func endUndoGrouping() {}
    override var groupingLevel: Int { 0 }
    override func removeAllActions() {}
    override func removeAllActions(withTarget target: Any) {}
    override func setActionName(_ actionName: String) {}

    override func undo() { around { history?.undo() } }
    override func redo() { around { history?.redo() } }
    override func undoNestedGroup() { undo() }
    override var canUndo: Bool { history?.canUndo ?? false }
    override var canRedo: Bool { history?.canRedo ?? false }
    override var isUndoing: Bool { history?.isUndoing ?? false }
    override var isRedoing: Bool { history?.isRedoing ?? false }
    override var undoActionName: String { history?.undoActionName ?? "" }
    override var redoActionName: String { history?.redoActionName ?? "" }
    override var undoMenuItemTitle: String { history?.undoMenuItemTitle ?? super.undoMenuItemTitle }
    override var redoMenuItemTitle: String { history?.redoMenuItemTitle ?? super.redoMenuItemTitle }
    override func undoMenuTitle(forUndoActionName name: String) -> String {
        history?.undoMenuTitle(forUndoActionName: name) ?? super.undoMenuTitle(forUndoActionName: name)
    }
    override func redoMenuTitle(forUndoActionName name: String) -> String {
        history?.redoMenuTitle(forUndoActionName: name) ?? super.redoMenuTitle(forUndoActionName: name)
    }

    private func around(_ body: () -> Void) {
        let tv = textView
        tv?.inputDelegate?.selectionWillChange(tv)
        tv?.inputDelegate?.textWillChange(tv)
        body()
        tv?.inputDelegate?.textDidChange(tv)
        tv?.inputDelegate?.selectionDidChange(tv)
    }
}
