// The two screens, Apple Notes' way: the list of notes (names only) and the editor, one push apart. The app opens on
// the editor with the last note; the list is the system Back, a swipe from the left edge.
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(Model.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            ListScreen()
                .navigationDestination(for: Route.self) { _ in EditorScreen() }
        }
        .onChange(of: model.path) { old, new in
            if new.isEmpty, !old.isEmpty { model.leftEditor() }
        }
        .background { UndoResponder(trigger: "\(model.path.count) \(model.keyboardUp) \(model.editingEnded)", active: !model.keyboardUp) }
    }
}

// MARK: the list

struct ListScreen: View {
    @Environment(Model.self) private var model
    @State private var renaming: UUID?
    @State private var scrollY: CGFloat = 0
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            let shown = model.shownRows
            let pinned = shown.filter(\.pinned), rest = shown.filter { !$0.pinned }
            if !pinned.isEmpty {
                Section("Pinned") { rows(pinned, pinned: true) }   // Notes' own heading
            }
            Section { rows(rest, pinned: false) }
        }
        .environment(\.editMode, .constant(model.selecting ? .active : .inactive))
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in scrollY = y }
        .overlay {
            // Over the list but moved with its scroll and rubber band, as Notes' «No Notes»: nothing re-lays out.
            if model.shownRows.isEmpty {
                Group {
                    if model.rows.isEmpty { ContentUnavailableView("No Notes", systemImage: "note.text") }
                    else { ContentUnavailableView.search(text: model.query) }
                }
                .offset(y: -scrollY)
                .allowsHitTesting(false)
            }
        }
        .animation(.default, value: model.rows)
        .navigationTitle(model.selecting ? selectedTitle : "Notes")
        .navigationSubtitle(model.selecting ? "" : (model.rows.isEmpty ? "No Notes" : model.rows.count == 1 ? "1 Note" : "\(model.rows.count) Notes"))
        .searchable(text: $model.query)
        .navigationBarTitleDisplayMode(model.selecting ? .inline : .large)
        .toolbar { toolbar }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let id = renaming, let n = model.library.note(id: id) { model.library.rename(n, to: newName) }
                renaming = nil
            }
        }
    }

    @ViewBuilder private func rows(_ list: [Row], pinned: Bool) -> some View {
        ForEach(list) { row in
            Button { model.open(row.id) } label: {
                // Notes' row: the name, then the time it was edited and the first text, as much as fits.
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.headline).lineLimit(1).foregroundStyle(Color.primary)
                    Text(NoteDate.text(row.modified) + "  " + (row.preview.isEmpty ? "No additional text" : row.preview))
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))   // not the button's tint
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                // Notes' orange pin.
                Button { model.togglePin([row.id]) } label: {
                    Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { model.delete([row.id]) } label: { Label("Delete", systemImage: "trash") }
            }
            .contextMenu {
                ControlGroup {
                    Button { model.copy([row.id]) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { model.delete([row.id]) } label: { Label("Delete", systemImage: "trash") }
                }
                Button { model.togglePin([row.id]) } label: {
                    Label(row.pinned ? "Unpin Note" : "Pin Note", systemImage: row.pinned ? "pin.slash" : "pin")
                }
                Button { newName = row.title; renaming = row.id } label: { Label("Rename", systemImage: "pencil") }
            } preview: {
                NotePreview(note: model.library.note(id: row.id))
            }
        }
        .onMove(perform: model.sort == .manual && model.found == nil ? { model.move(pinned: pinned, from: $0, to: $1) } : nil)
    }

    private var selectedTitle: String { "\(model.selection.count) selected" }   // Notes' own words: «%@ selected»

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.selecting { selectToolbar } else { listToolbar }
    }

    @ToolbarContentBuilder private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { model.selecting = true } label: { Label("Select Notes", systemImage: "checkmark.circle") }
                    .disabled(model.rows.isEmpty)
                SortMenu()
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button { model.compose() } label: { Label("New Note", systemImage: "square.and.pencil") }
        }
    }

    @ToolbarContentBuilder private var selectToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.selection.count == model.rows.count {
                Button("Deselect All") { model.selection = [] }
            } else {
                Button("Select All") { model.selectAll() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", systemImage: "checkmark", role: .confirm) { model.selecting = false }
        }
        // With nothing ticked the bar acts on every note, as Notes' Delete All (his word: everything deleted or copied
        // without selecting each).
        ToolbarItem(placement: .bottomBar) {
            Button(model.selection.isEmpty ? "Copy All" : "Copy") {
                model.copy(model.selection.isEmpty ? Set(model.rows.map(\.id)) : model.selection)
                model.selecting = false
            }
        }
        ToolbarSpacer(placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(model.allPinned(model.selection) ? "Unpin" : "Pin") {
                model.togglePin(model.selection)
                model.selecting = false
            }
            .disabled(model.selection.isEmpty)
        }
        ToolbarSpacer(placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(model.selection.isEmpty ? "Delete All" : "Delete", role: .destructive) {
                model.delete(model.selection.isEmpty ? Set(model.rows.map(\.id)) : model.selection)
                if model.rows.isEmpty { model.selecting = false }
            }
        }
    }
}

/// Sort By as in Notes, with Reminders' Manual: the order, then the direction its kind takes (Newest First / Oldest
/// First for dates, Ascending / Descending for titles; the manual order has none). Synced through the core.
struct SortMenu: View {
    @Environment(Model.self) private var model

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { model.sort }, set: { model.setSort($0) })) {
                Text("Manual").tag(Library.Sort.manual)
                Text("Date Edited").tag(Library.Sort.edited)
                Text("Date Created").tag(Library.Sort.created)
                Text("Title").tag(Library.Sort.title)
            } label: { EmptyView() }
            .pickerStyle(.inline)
            if model.sort != .manual {
                Picker(selection: Binding(get: { model.ascending }, set: { model.setAscending($0) })) {
                    if model.sort == .title {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    } else {
                        Text("Newest First").tag(false)
                        Text("Oldest First").tag(true)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
            Text(name)
        }
    }

    private var name: String {
        switch model.sort {
        case .manual: "Manual"
        case .edited: "Date Edited"
        case .created: "Date Created"
        case .title: "Title"
        }
    }
}

/// The long-press preview: the note's first lines, as Notes previews a note.
struct NotePreview: View {
    let note: Note?
    var body: some View {
        let text = note.map { n in n.storage.mutableString.substring(to: min(n.length, 1200)) } ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Text(note?.title ?? "").font(.headline).lineLimit(1)
            Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 320, height: 380, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: the editor

struct EditorScreen: View {
    @Environment(Model.self) private var model

    var body: some View {
        EditorHost(note: model.current?.id, editors: model.editors)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .navigationTitle(Binding(get: { _ = model.titleVersion; return model.keyboardUp ? "" : model.current?.title ?? "" },
                                     set: { model.rename(to: $0) }))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                // As Notes on iOS 27: Undo (held: Redo) once there is something to undo, Share and More together,
                // the checkmark while typing. While typing the name steps aside (Notes shows none): beside it the four
                // did not fit, and iOS folded the checkmark into an overflow menu that showed the word «Done».
                if model.canUndo || model.canRedo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                                .disabled(!model.canRedo)
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        } primaryAction: {
                            model.undo()
                        }
                        .disabled(!model.canUndo)
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // The share sheet grows out of this button, as in Notes (Editors.share anchors it here).
                    Button { model.editors.share() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        .disabled(model.facts?.characters == 0)
                    Menu {
                        // Text size as Safari's Page Zoom: small A, the percentage (back to 100 %), big A; the menu
                        // stays open while stepping, the text rewraps under it.
                        ControlGroup {
                            Button { model.editors.stepTextSize(-1) } label: {
                                Label("Smaller", systemImage: "textformat.size.smaller")
                            }
                            .disabled(model.textSize <= Library.textSizes.first!)
                            Button { model.editors.stepTextSize(0) } label: { Text("\(model.textSize)%") }
                                .accessibilityLabel("Text Size \(model.textSize)%, Actual Size")
                            Button { model.editors.stepTextSize(1) } label: {
                                Label("Bigger", systemImage: "textformat.size.larger")
                            }
                            .disabled(model.textSize >= Library.textSizes.last!)
                        }
                        .controlGroupStyle(.compactMenu)
                        .menuActionDismissBehavior(.disabled)
                        Button { model.editors.findInNote() } label: { Label("Find in Note", systemImage: "magnifyingglass") }
                        Button(role: .destructive) { model.deleteOpen() } label: { Label("Delete", systemImage: "trash") }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
                if model.keyboardUp {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", systemImage: "checkmark", role: .confirm) { model.endEditing() }
                    }
                }
            }
            // Keyboard down: the counter and New Note in the same fixed bar as over the keyboard (Editors.bottomBar), over
            // the text with a fade behind it as a toolbar's edge. Keyboard up: the keyboard's own bar. An overlay leaves
            // the safe areas as they are; the text view keeps room under its last line (Editors.keyboard(up:)).
            .overlay(alignment: .bottom) {
                if !model.keyboardUp {
                    BarHost(bar: model.editors.bottomBar)
                        .frame(height: 56)
                        .background {
                            // A 24-point fade above the bar, solid behind it and down to the screen's edge, so no text
                            // shows through the counter.
                            VStack(spacing: 0) {
                                LinearGradient(colors: [Color(uiColor: .systemBackground).opacity(0), Color(uiColor: .systemBackground)],
                                               startPoint: .top, endPoint: .bottom)
                                    .frame(height: 24)
                                Color(uiColor: .systemBackground)
                            }
                            .padding(.top, -24)
                            .ignoresSafeArea(edges: .bottom)
                        }
                }
            }
    }
}

struct BarHost: UIViewRepresentable {
    let bar: KeyboardBar
    func makeUIView(context: Context) -> KeyboardBar { bar }
    func updateUIView(_ v: KeyboardBar, context: Context) {}
}

/// Notes' dates in a row: the time today, «Yesterday», the weekday within a week, else the short date.
enum NoteDate {
    static func text(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7, days > 0 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(date: .numeric, time: .omitted)
    }
}

struct EditorHost: UIViewRepresentable {
    let note: UUID?
    let editors: Editors

    /// SwiftUI may build a new host before it lets the old one go (a pose change on iPhone Duo, a size-class change):
    /// each host is its own slot, and the slot on screen adopts the one container, so an old host leaving takes
    /// nothing with it.
    final class Slot: UIView {
        weak var editors: Editors?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { adopt() }
        }
        func adopt() {
            guard let c = editors?.container else { return }
            if c.superview !== self {
                c.frame = bounds
                c.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(c)
            }
            editors?.showCurrent()
        }
    }

    func makeUIView(context: Context) -> Slot {
        let s = Slot()
        s.editors = editors
        s.preservesSuperviewLayoutMargins = true
        return s
    }

    func updateUIView(_ slot: Slot, context: Context) {
        if slot.window != nil { slot.adopt() } else { editors.showCurrent() }
    }
}

/// Shake to undo and ⌘Z with the keyboard down (the list, a note being read): UIKit asks the first responder for its
/// undo manager and shows nothing when there is none, so an invisible first responder holds whenever no text does;
/// its manager is the window's (the History's).
struct UndoResponder: UIViewRepresentable {
    let trigger: String
    let active: Bool

    final class View: UIView {
        override var canBecomeFirstResponder: Bool { true }
        override var undoManager: UndoManager? { window?.undoManager }
    }

    func makeUIView(context: Context) -> View {
        let v = View()
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        return v
    }

    func updateUIView(_ v: View, context: Context) {
        guard active else { return }
        // After the push or pop has settled, and only if nothing else (a text field, the search) holds the keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard v.window != nil, !(v.window?.firstResponderIsText ?? false) else { return }
            v.becomeFirstResponder()
        }
    }
}

extension UIWindow {
    /// Whether a text view or field is first responder (found by asking it to report itself).
    var firstResponderIsText: Bool {
        var found: UIResponder?
        UIApplication.shared.sendAction(#selector(UIResponder.merumReport(_:)), to: nil, from: Box { found = $0 }, for: nil)
        return found is UITextInput
    }
}

final class Box: NSObject {
    let call: (UIResponder) -> Void
    init(_ call: @escaping (UIResponder) -> Void) { self.call = call }
}

extension UIResponder {
    @objc func merumReport(_ sender: Any?) { (sender as? Box)?.call(self) }
}
