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

/// Holds the text view of the note on screen, and the dock that keeps the counter bar on screen with the keyboard down.
///
/// The bar is one view, the input accessory of whatever holds the editor's input: the text view while typing (the
/// bar rides on the keyboard), the dock while the keyboard is down (the bar alone at the bottom, as Messages keeps its
/// entry field). The keyboard and its accessory are one piece that UIKit moves together, so the bar follows the
/// keyboard to the frame, the finger's interactive dismissal included, and stops where the keyboard leaves it. The 0.2
/// build had a second bar for the keyboard down in the editor itself: both showed on every dismiss, 56 points apart,
/// and SwiftUI's keyboard avoidance moved the second one in an animation of its own, 22 points short, then a jump.
/// A bar of the editor tied to the keyboard layout guide (tried) trailed the keyboard by up to 30 points mid-animation.
final class EditorContainer: UIView {
    private(set) var shown: NoteTextView?
    let dock: EditorDock

    /// The background over the text where the keyboard and the bar are: the keyboard's glass would show the text
    /// under it, cut by its rounded corners. Tied to the keyboard layout guide, whose top is the bar's top (the bar is
    /// part of the keyboard); behind the bar's own solid strip, so the guide's few points of lag mid-animation stay
    /// hidden.
    private let cover = UIView()
    /// Behind the navigation bar's buttons, over the text: a line scrolled up there is hidden, never drawn under the
    /// buttons (the system's soft scroll edge effect, which a text view hosted by SwiftUI gets, blurred only the status
    /// bar's 25 points; its hard style drew a divider line even with the text at its top).
    let topShield = TopShield()

    init(bar: KeyboardBar) {
        dock = EditorDock(bar: bar)
        super.init(frame: .zero)
        // The screen's margins (system minimum plus safe area) reach the text view, so text lines up with the title.
        preservesSuperviewLayoutMargins = true
        addSubview(dock)
        cover.backgroundColor = .systemBackground
        cover.isUserInteractionEnabled = false
        cover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cover)
        addSubview(topShield)
        topShield.translatesAutoresizingMaskIntoConstraints = false
        keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor),
            cover.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            topShield.topAnchor.constraint(equalTo: topAnchor),
            topShield.leadingAnchor.constraint(equalTo: leadingAnchor),
            topShield.trailingAnchor.constraint(equalTo: trailingAnchor),
            topShield.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the view on screen; the one it replaces stays until the caller has moved the input (`retire`), so the
    /// keyboard passes from one note to the next without going down.
    func show(_ tv: NoteTextView) -> NoteTextView? {
        guard shown !== tv else { return nil }
        let old = shown
        tv.frame = bounds
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(tv, belowSubview: cover)
        shown = tv
        return old
    }
}

/// See EditorContainer.topShield: solid where the navigation bar's buttons are, fading out over the last 18 points
/// above the safe area's top, where the first line rests.
final class TopShield: UIView {
    private let solid = UIView()
    private let fade = Fade(reversed: true)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        solid.backgroundColor = .systemBackground
        for v in [solid, fade] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            solid.topAnchor.constraint(equalTo: topAnchor),
            solid.leadingAnchor.constraint(equalTo: leadingAnchor),
            solid.trailingAnchor.constraint(equalTo: trailingAnchor),
            fade.topAnchor.constraint(equalTo: solid.bottomAnchor),
            fade.leadingAnchor.constraint(equalTo: leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: bottomAnchor),
            fade.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Holds the input (and so the counter bar, its accessory) while no text does in the editor; its undo is the window's,
/// the one History, so shake and ⌘Z work here as on the list.
final class EditorDock: UIView {
    let bar: KeyboardBar
    /// Off while the editor is not the screen in front (the list, a push or pop in progress).
    var enabled = false

    init(bar: KeyboardBar) {
        self.bar = bar
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { enabled && window != nil }
    override func becomeFirstResponder() -> Bool {
        bar.under = window?.safeAreaInsets.bottom ?? 0
        bar.fit(to: window)
        return super.becomeFirstResponder()
    }
    override var inputAccessoryView: UIView? { bar }
    override var undoManager: UndoManager? { window?.undoManager }
}

@MainActor final class Editors: NSObject, UITextViewDelegate, NSTextStorageDelegate {
    weak var model: Model?
    let library: Library
    let container: EditorContainer
    /// The next note shown takes the keyboard: a note always opens ready to type, at launch and from the list alike
    /// (his decision 2026-11-25: «просто всегда открывать клавиатуру»); a swipe down on the text puts it away.
    var focusNext = false
    /// With focusNext: the caret goes to the end of the note first (the App Shortcuts and the control, Launch.swift).
    var caretToEnd = false

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

    /// The counter and New Note, over the keyboard or at the bottom (EditorContainer places it). A plain view, not a
    /// toolbar: a toolbar folds what does not fit into an overflow «…», which once swallowed New Note (an extra tap).
    /// Here New Note is a fixed 44-point glass button on the right, the size of the bars' own buttons, and the counter
    /// is centred, held clear of it by constraints (KeyboardBar).
    let bar: KeyboardBar

    /// Room under the text for what covers the screen's bottom: the keyboard with the bar, or the bar alone (the safe
    /// area under it is added by UIKit). Set inside the keyboard's own animation (Model's keyboard observer).
    private(set) var keyboardInset: CGFloat = KeyboardBar.height
    func keyboard(frame end: CGRect, duration: Double, curve: UInt) {
        // The bar alone at the screen's bottom while the text view keeps the input: the end of a finger's dismissal
        // (UIKit lets the text view go a moment after the keyboard has gone) or a hardware keyboard. It stands above
        // the home indicator then, as in the dock; over the software keyboard it has no room under it.
        if let tv = container.shown, tv.isFirstResponder, end.height > 0 {
            let alone = end.height <= bar.frame.height + 1
            bar.under = alone ? (container.window?.safeAreaInsets.bottom ?? 0) : 0
        }
        bar.settle(duration: duration, curve: curve)
        guard let tv = container.shown ?? views.values.first, let w = container.window else { return }
        let top = container.convert(w.convert(end, from: nil), from: w).minY   // the screen's coordinates into ours
        let covered = max(0, container.bounds.maxY - top)
        let inset = max(KeyboardBar.height, covered - tv.safeAreaInsets.bottom)
        if tv.isFirstResponder, end.height > bar.frame.height + 1 { typingInset = inset }
        guard inset != keyboardInset else { return }
        keyboardInset = inset
        for v in views.values { Editors.setInset(inset, of: v) }
    }

    /// The room the keyboard and the bar took last time (a first guess before the keyboard has been seen): a note
    /// opening with the keyboard coming up gets it at once, so its end is placed above where the keyboard will stop
    /// and nothing scrolls when it arrives (it scrolled in three jumps, 236, 77 and 44 points, after the push).
    private var typingInset: CGFloat?

    private static func setInset(_ inset: CGFloat, of v: UITextView) {
        if v.contentInset.bottom != inset { v.contentInset.bottom = inset }
        if v.verticalScrollIndicatorInsets.bottom != inset { v.verticalScrollIndicatorInsets.bottom = inset }
    }

    func showFacts(_ facts: Facts?) { bar.facts = facts }

    init(model: Model) {
        self.model = model
        library = model.library
        bar = KeyboardBar(compose: {})
        container = EditorContainer(bar: bar)
        super.init()
        // Another field let the input go (Find in Note's field closed, a rename): the dock takes it back once the turn
        // is over and nothing else has.
        NotificationCenter.default.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dockIfIdle() } }
        }
        // Builds up to 0.2 kept each note's caret here; a note now always opens at its end.
        UserDefaults.standard.removeObject(forKey: "caret")
        bar.compose = { [weak self] in self?.model?.compose() }
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
        tv.inputAccessoryView = bar
        tv.contentInset.bottom = keyboardInset
        tv.verticalScrollIndicatorInsets.bottom = keyboardInset
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
        // While the input passes from the note left to this one, the dock stays out of it.
        otherInput = true
        let old = container.show(tv)
        container.dock.enabled = true
        // Taken the moment a push ends, so the keyboard rises from the bottom as in Notes (his recording: push, then
        // the keyboard up); taken during the push it slid in sideways after it. At once when nothing is moving.
        if focusNext, tv.window != nil {
            focusNext = false
            if caretToEnd {
                caretToEnd = false
                tv.selectedRange = NSRange(location: tv.textStorage.length, length: 0)
                tv.scrollRangeToVisible(tv.selectedRange)
            }
            let vc = sequence(first: tv as UIResponder, next: \.next).compactMap { $0 as? UIViewController }.first
            if let tc = vc?.transitionCoordinator {
                // Not earlier: during the transition UIKit carries the keyboard in sideways with the view (tried at
                // the push's start and at its 0.35 s duration). Its completion (~0.53 s, the spring settled) gives
                // Notes' order: the push, then the keyboard rising, ~0.2 s after the push looks done (Notes: ~0.3 s).
                tc.animate(alongsideTransition: nil) { [weak tv] ctx in
                    if !ctx.isCancelled, tv?.window != nil { tv?.becomeFirstResponder() }
                }
            } else {
                // The new note takes the input before the old view goes: the keyboard stays up between them.
                tv.becomeFirstResponder()
            }
        }
        if let old {
            if old.isFirstResponder { _ = old.resignFirstResponder() }
            old.removeFromSuperview()
        }
        otherInput = false
        dockIfIdle()
    }

    /// The editor left the screen: the bar goes with it.
    func leave() {
        container.dock.enabled = false
        container.shown?.resignFirstResponder()
        if container.dock.isFirstResponder { container.dock.resignFirstResponder() }
    }

    // MARK: the caret

    /// The caret of a note being opened (launch, the list, New Note, the Action button): always at the end of its
    /// text, scrolled into view, the keyboard coming up, so typing goes on where the text ends (his decision
    /// 2026-11-26). Until then each note's caret was stored on this device and put back, so some notes opened at
    /// their start and others at their end, the same way each time.
    func openAtEnd(_ note: Note) {
        let tv = view(for: note)
        editing = true
        tv.selectedRange = NSRange(location: note.storage.length, length: 0)
        editing = false
        if !tv.isFirstResponder {
            let guess = typingInset ?? (container.window?.bounds.height ?? 852) * 0.42
            keyboardInset = guess
            for v in views.values { Editors.setInset(guess, of: v) }
        }
        tv.endPending = true
        tv.setNeedsLayout()
    }

    func endEditing() { container.shown?.resignFirstResponder() }

    /// The Undo button and its Redo: through the shown view's manager, so the keyboard hears of the change.
    func undo() { (container.shown?.undoManager ?? library.history.undoManager).undo() }
    func redo() { (container.shown?.undoManager ?? library.history.undoManager).redo() }

    func findInNote() {
        guard let tv = container.shown else { return }
        otherInput = true
        tv.findInteraction?.presentFindNavigator(showingReplace: false)
        otherInput = false
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
        (tv as? NoteTextView)?.endPending = false
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

    /// The keyboard went down (Done, a swipe, the finger's drag): the dock takes the input in the same turn, so UIKit
    /// moves the keyboard away and leaves the bar, one change, instead of taking both away and bringing the bar back.
    func textViewDidEndEditing(_ tv: UITextView) {
        dockIfIdle()
    }

    /// Whether the dock should take the input from the text view leaving it: the editor in front, and no other input
    /// on its way in (Find in Note's field).
    var dockTakesOver: Bool {
        let d = container.dock
        return d.enabled && d.window != nil && !d.isFirstResponder && !otherInput
    }
    /// Set while something else takes the input from the text view on purpose.
    var otherInput = false

    /// The dock holds the input whenever the editor is in front and nothing else does.
    func dockIfIdle() {
        let d = container.dock
        guard d.enabled, !otherInput, d.window != nil, !d.isFirstResponder, !(d.window?.firstResponderIsSomething ?? true) else { return }
        d.becomeFirstResponder()
    }

    func scrollViewWillBeginDragging(_ sv: UIScrollView) { (sv as? NoteTextView)?.endPending = false }

    func textViewDidChangeSelection(_ tv: UITextView) {
        guard !editing, tv.markedTextRange == nil else { return }
        (tv as? NoteTextView)?.endPending = false
        library.history.breakTyping()
    }

    /// Paste, cut and the text of a picture: straight into the storage, one History step.
    func replace(_ range: NSRange, with string: String, in tv: NoteTextView, kind: History.Kind) {
        tv.endPending = false
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
        // Placed as UIKit's typing places it (the caret's line just above the bar), so the Return that follows does not
        // move the text again: scrollRangeToVisible stopped 85 points higher on a non-contiguous layout, and the next
        // Return pulled the text back down in one frame (his recording: 76 down, then 29 up).
        tv.scrollCaretIntoView(animated: true)
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

    override func becomeFirstResponder() -> Bool {
        (inputAccessoryView as? KeyboardBar)?.under = 0
        (inputAccessoryView as? KeyboardBar)?.fit(to: window)
        return super.becomeFirstResponder()
    }

    private var handingOver = false
    /// Going off the keyboard hands the input straight to the dock: one change of inputs, which UIKit animates as the
    /// keyboard leaving and the bar staying. A plain resign and then the dock taking over were two changes: the bar went
    /// down with the keyboard nearly off the screen and came back up (measured: 80 points past its rest).
    override func resignFirstResponder() -> Bool {
        if !handingOver, isFirstResponder, let ed = editors, ed.dockTakesOver {
            handingOver = true
            defer { handingOver = false }
            return ed.container.dock.becomeFirstResponder() || super.resignFirstResponder()
        }
        return super.resignFirstResponder()
    }

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
        if endPending, window != nil, bounds.height > 0 { scrollToEnd() }
    }

    /// A note just opened keeps its end in view (Editors.openAtEnd) through the push, the safe area arriving and the
    /// keyboard, until the person scrolls, moves the caret or types.
    var endPending = false
    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        if endPending { setNeedsLayout() }
    }

    /// The end of the text just above the keyboard (or the bar), without animation.
    private func scrollToEnd() {
        selectedRange = NSRange(location: textStorage.length, length: 0)
        scrollCaretIntoView(animated: false)
    }

    /// The caret's line into view by UIKit's own rule for typing: its bottom (plus the text's bottom inset) at the
    /// bottom of what is visible, or its top at the top; nothing moves when it is visible. The line comes from the
    /// layout itself: on a non-contiguous layout scrollRangeToVisible stopped short of it. A move of up to two screens
    /// is animated; a longer one (a book pasted) is made at once, so the layout of everything between is not drawn.
    func scrollCaretIntoView(animated: Bool) {
        let lm = layoutManager
        let at = selectedRange.location + selectedRange.length
        let length = textStorage.length
        lm.ensureLayout(forCharacterRange: NSRange(location: max(0, min(at, length) - 1), length: min(1, length)))
        var line: CGRect
        if at >= length, !lm.extraLineFragmentRect.isEmpty || lm.numberOfGlyphs == 0 {
            line = lm.extraLineFragmentRect
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(at, max(0, length - 1)))
            line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let top = line.minY + textContainerInset.top
        let bottom = line.maxY + textContainerInset.top + textContainerInset.bottom
        let a = adjustedContentInset
        var y = contentOffset.y
        if bottom > y + bounds.height - a.bottom { y = bottom + a.bottom - bounds.height }
        else if top - textContainerInset.top < y + a.top { y = top - textContainerInset.top - a.top }
        y = max(-a.top, y)
        guard abs(y - contentOffset.y) > 0.5 else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: animated && abs(y - contentOffset.y) < 2 * bounds.height)
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


/// The counter over the keyboard and New Note. Whatever the count, width or text size, New Note keeps its place and
/// size and the counter never reaches it.
final class KeyboardBar: UIInputView {
    private let label = UILabel()
    private let button = UIButton(configuration: .glass())
    private let fade = Fade()
    private let solid = UIView()
    var facts: Facts? { didSet { if facts != oldValue { update() } } }
    private static let side: CGFloat = 16, gap: CGFloat = 8, size: CGFloat = 44
    static let height: CGFloat = 56
    var compose: () -> Void
    /// The bar's height as UIKit's input host reads it (a constraint: the host ignores a changed frame).
    private lazy var tall = heightAnchor.constraint(equalToConstant: KeyboardBar.height)
    private lazy var rowBottom = row.bottomAnchor.constraint(equalTo: bottomAnchor)
    private let row = UILayoutGuide()

    init(compose: @escaping () -> Void) {
        self.compose = compose
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: KeyboardBar.height), inputViewStyle: .default)
        // Sized by its height constraint (`tall`), which the input host follows only for a self-sizing input view.
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        // The bar's text stops growing at the largest standard size, as the system bars' labels do.
        maximumContentSizeCategory = .extraExtraExtraLarge
        var c = UIButton.Configuration.glass()
        // A fixed size, as the bars' own buttons keep theirs at every text size.
        let symbol = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        c.image = UIImage(systemName: "square.and.pencil", withConfiguration: symbol)
        c.preferredSymbolConfigurationForImage = symbol
        c.cornerStyle = .capsule
        button.configuration = c
        button.addAction(UIAction { [weak self] _ in self?.compose() }, for: .primaryActionTriggered)
        button.accessibilityLabel = "New Note"
        button.maximumContentSizeCategory = .large   // the glyph keeps the bars' buttons' size at every text size
        label.font = KeyboardBar.font(for: traitCollection)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.lineBreakMode = .byClipping
        label.adjustsFontSizeToFitWidth = true   // the last resort, after the shorter forms
        label.minimumScaleFactor = 0.5
        // Behind the row, solid down to the bar's bottom (the home indicator's strip too) with a 24-point fade above it,
        // so the text scrolling under the counter never shows through it. Part of the bar: it moves with it, frame by
        // frame (in the 0.2 build it was SwiftUI's, laid out by the keyboard's safe area, and vanished mid-drag).
        fade.isUserInteractionEnabled = false
        solid.isUserInteractionEnabled = false
        solid.backgroundColor = .systemBackground
        for v in [fade, solid, label, button] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let (side, gap, size) = (KeyboardBar.side, KeyboardBar.gap, KeyboardBar.size)
        // Inside the safe area: on iPhone Duo's outer display the system bars stand at the right edge (84 points).
        let safe = safeAreaLayoutGuide
        addLayoutGuide(row)
        NSLayoutConstraint.activate([
            tall,
            rowBottom,
            solid.topAnchor.constraint(equalTo: row.topAnchor),
            solid.bottomAnchor.constraint(equalTo: bottomAnchor),
            solid.leadingAnchor.constraint(equalTo: leadingAnchor),
            solid.trailingAnchor.constraint(equalTo: trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: row.topAnchor),
            fade.heightAnchor.constraint(equalToConstant: 24),
            fade.leadingAnchor.constraint(equalTo: leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: KeyboardBar.height),
            button.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -side),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: side),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -gap),
            // Symmetric room on the left, so a centred counter never runs under New Note's mirror image.
            label.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: side + size + gap)
                .withPriority(.defaultHigh),
            // Centred while it can be; never at the price of overlapping New Note.
            label.centerXAnchor.constraint(equalTo: safe.centerXAnchor).withPriority(.defaultHigh),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Room under the row: the home indicator's safe area while the bar stands alone at the screen's bottom (the dock),
    /// none over the keyboard. Set before the input changes hands, so UIKit sizes the bar once for each place. UIKit
    /// gives the bar its new height at the start of the move, around the bar's bottom (the keyboard's top), so the row
    /// first keeps its place (`lift` as it was) and then moves along with the keyboard (`settle`).
    var under: CGFloat = 0 {
        didSet {
            guard under != oldValue else { return }
            UIView.performWithoutAnimation {
                tall.constant = KeyboardBar.height + under
                lift = oldValue
                layoutIfNeeded()
            }
        }
    }
    /// The window's width and the counter laid out for it before UIKit first shows the bar: at launch the bar came up
    /// 320 points wide and the counter's text grew letter by letter inside the keyboard's animation.
    func fit(to window: UIWindow?) {
        guard let w = window?.bounds.width, w > 0, abs(bounds.width - w) > 0.5 else { return }
        UIView.performWithoutAnimation {
            frame.size.width = w
            setNeedsLayout()
            layoutIfNeeded()
            update()
            layoutIfNeeded()
        }
    }

    /// How far the row stands above the bar's bottom.
    private var lift: CGFloat = 0 { didSet { rowBottom.constant = -lift } }
    /// With the keyboard's animation (its duration and curve, from its notification): the row goes to its place in
    /// the new height, along with the bar's move. The notification of a dock taking over comes outside any animation.
    func settle(duration: Double, curve: UInt) {
        guard lift != under else { return }
        // Going down to the dock, UIKit starts moving the bar on the next turn of the run loop, after this notification:
        // the row's own move starts with it (started here, it ran a frame ahead and the row rose 2 to 11 points first).
        if under > lift {
            DispatchQueue.main.async { [weak self] in self?.animateLift(duration: duration, curve: curve) }
        } else {
            animateLift(duration: duration, curve: curve)
        }
    }
    private func animateLift(duration: Double, curve: UInt) {
        guard lift != under else { return }
        lift = under
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
            self.layoutIfNeeded()
        }
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: KeyboardBar.height + under) }
    override func layoutSubviews() { super.layoutSubviews(); update() }
    override func traitCollectionDidChange(_ previous: UITraitCollection?) { super.traitCollectionDidChange(previous); update() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); update() }

    private func update() {
        let room = safeAreaLayoutGuide.layoutFrame.width - 2 * (KeyboardBar.side + KeyboardBar.size + KeyboardBar.gap)
        let font = KeyboardBar.font(for: traitCollection)
        if label.font != font { label.font = font }
        let text = KeyboardBar.fit(facts, width: room, font: font)
        if label.text != text { label.text = text }
        label.accessibilityLabel = facts.map { $0.lines.joined(separator: ", ") }
    }

    /// The counter's font: caption at the person's text size, capped at the largest standard one.
    static func font(for traits: UITraitCollection) -> UIFont {
        let p = traits.preferredContentSizeCategory
        let size: UIContentSizeCategory = p.isAccessibilityCategory ? .extraExtraExtraLarge : p
        return .preferredFont(forTextStyle: .caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: size))
    }

    // MARK: the forms, longest first

    /// One wording in every note, short enough for the narrowest bar: «3,230 chars · 660 words · ≈ 810 tokens».
    /// Only the numbers shorten when even that does not fit («3M chars · 464K words · ≈ 999K tokens»). Until 0.2 the
    /// words themselves changed with the width the numbers left («30 Characters…» in one note, «… chars…» in the next).
    static func full(_ f: Facts) -> String { line(f) { $0.formatted(.number) } }
    static func compact(_ f: Facts) -> String { line(f) { $0.formatted(.number.notation(.compactName)) } }
    private static func line(_ f: Facts, _ number: (Int) -> String) -> String {
        func n(_ v: Int, _ one: String, _ many: String) -> String { "\(number(v)) \(v == 1 ? one : many)" }
        return [n(f.characters, "char", "chars"), n(f.words, "word", "words"), "≈\u{00A0}" + n(f.tokens, "token", "tokens")]
            .joined(separator: " · ")
    }
    /// The longest form that fits the width at the font's own size; the shorter one when none does (the label then
    /// shrinks its font a little).
    static func fit(_ f: Facts?, width: CGFloat, font: UIFont) -> String {
        guard let f else { return " " }
        let forms = [full(f), compact(f)]
        return forms.first { ($0 as NSString).size(withAttributes: [.font: font]).width <= width } ?? forms.last!
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint { priority = p; return self }
}

/// The system background fading in from clear, top to bottom (reversed: fading out), in the current appearance.
final class Fade: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private let reversed: Bool
    init(reversed: Bool = false) {
        self.reversed = reversed
        super.init(frame: .zero)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (v: Fade, _) in v.paint() }
        paint()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func paint() {
        let c = UIColor.systemBackground.resolvedColor(with: traitCollection)
        let colors = [c.withAlphaComponent(0).cgColor, c.cgColor]
        (layer as! CAGradientLayer).colors = reversed ? colors.reversed() : colors
    }
}
