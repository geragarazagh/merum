// The menu bar, shown while the window is (the app is a regular app then; App.show). Apple Notes' menus on macOS 27.2
// are the model, item for item, minus what a plain-text app has no use for (formatting, attachments, folders, links,
// tables, checklists); every name is Apple's own English. What only Merum has goes where Apple puts the like of it:
// Rename in Edit (as Notes), the text size in View as Zoom In / Zoom Out / Actual Size (Notes' and Safari's words),
// Sort By in View with Manual (Reminders' word), the first nine notes in Window with ⌘1…⌘9, Keep on Top in Window (as
// Notes 27 has it).
import AppKit

@MainActor final class Menus {
    private let noteItems: [NSMenuItem]
    private let windowMenu = NSMenu(title: "Window")

    init(app: App) {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Merum"
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            it.target = target
            it.tag = tag
            return it
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            it.submenu = m
            return it
        }
        func top(_ m: NSMenu) { let it = NSMenuItem(title: m.title, action: nil, keyEquivalent: ""); it.submenu = m; main.addItem(it) }

        // Merum
        let appMenu = NSMenu(title: name)
        appMenu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(item("Check for Updates…", #selector(Updates.check), target: Updates.shared))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(App.showSettings(_:)), ",", target: app))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(submenu("Services", []))
        appMenu.items.last?.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(name)", #selector(App.hideFromMenu(_:)), "h", target: app))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        top(appMenu)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New Note", #selector(MainWindow.newNote(_:)), "n"))
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(.separator())
        file.addItem(item("Save…", #selector(MainWindow.saveNote(_:)), "s"))
        file.addItem(.separator())
        // Apple Notes' File menu has Pin Note with no key; its title follows what it acts on (MainWindow.pinTitle).
        file.addItem(item("Pin Note", #selector(MainWindow.pinNotes(_:))))
        top(file)

        // Edit. Delete shows ⌫ as Notes' does: in the list it deletes the selected notes, in the text the selection.
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        edit.addItem(item("Delete", #selector(NSText.delete(_:)), "\u{8}", []))
        edit.addItem(item("Rename", #selector(MainWindow.renameNote(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = #selector(NSTextView.performFindPanelAction(_:))
        edit.addItem(submenu("Find", [
            // Apple Notes' keys: ⌥⌘F searches the list, ⇧⌘F finds and replaces in the note.
            item("Note List Search…", #selector(MainWindow.searchNotes(_:)), "f", [.command, .option]),
            .separator(),
            item("Find…", find, "f", tag: NSTextFinder.Action.showFindInterface.rawValue),
            item("Find and Replace…", find, "f", [.command, .shift], tag: NSTextFinder.Action.showReplaceInterface.rawValue),
            item("Find Next", find, "g", tag: NSTextFinder.Action.nextMatch.rawValue),
            item("Find Previous", find, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue),
            .separator(),
            item("Use Selection for Find", find, "e", tag: NSTextFinder.Action.setSearchString.rawValue),
            item("Jump to Selection", #selector(NSTextView.centerSelectionInVisibleArea(_:)), "j"),
        ]))
        edit.addItem(submenu("Spelling and Grammar", [
            item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
            .separator(),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
            item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
            item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
        ]))
        edit.addItem(submenu("Substitutions", [
            item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
            .separator(),
            item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))),
            item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
            item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
            item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
        ]))
        edit.addItem(submenu("Transformations", [
            item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))),
            item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))),
            item("Capitalize", #selector(NSResponder.capitalizeWord(_:))),
        ]))
        edit.addItem(submenu("Speech", [
            item("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
            item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))),
        ]))
        // AutoFill, Start Dictation and Emoji & Symbols are added here by AppKit, as in every app's Edit menu.
        top(edit)

        // View
        let view = NSMenu(title: "View")
        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = Menus.sortMenu()
        view.addItem(sortItem)
        view.addItem(.separator())
        view.addItem(item("Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(item("Notes List", #selector(MainWindow.showNotesList(_:)), "l"))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(MainWindow.zoomIn(_:)), "+"))
        // ⌘= is the same key as ⌘+ without ⇧ on most layouts: it zooms in too, unseen, as in Safari.
        let zoomInAlt = item("Zoom In", #selector(MainWindow.zoomIn(_:)), "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomInAlt)
        view.addItem(item("Zoom Out", #selector(MainWindow.zoomOut(_:)), "-"))
        view.addItem(item("Actual Size", #selector(MainWindow.actualSize(_:)), "0"))
        top(view)

        // Window: AppKit adds its own items (Fill, Center, Move & Resize, the window list) as it does for Notes.
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Keep on Top", #selector(MainWindow.toggleKeepOnTop(_:))))
        windowMenu.addItem(.separator())
        var notes: [NSMenuItem] = []
        for i in 0..<9 {
            let it = item("", #selector(MainWindow.openNoteAtIndex(_:)), "\(i + 1)", tag: i)
            windowMenu.addItem(it)
            notes.append(it)
        }
        noteItems = notes
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        top(windowMenu)
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        top(help)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    /// Sort By, for the View menu and the toolbar's «…» menu. Dates read Newest First / Oldest First (Notes), titles
    /// Ascending / Descending (Reminders); only the pair that fits the sort shows, and none for Manual, which has no
    /// direction (MainWindow.validateMenuItem).
    static func sortMenu() -> NSMenu {
        let m = NSMenu(title: "Sort By")
        for (title, s) in [("Manual", Library.Sort.manual), ("Date Edited", .edited), ("Date Created", .created), ("Title", .title)] {
            let it = NSMenuItem(title: title, action: #selector(MainWindow.sortBy(_:)), keyEquivalent: "")
            it.representedObject = s.rawValue
            m.addItem(it)
        }
        m.addItem(.separator())
        for (title, tag, kind) in [("Newest First", 1, "date"), ("Oldest First", 0, "date"), ("Ascending", 0, "title"), ("Descending", 1, "title")] {
            let it = NSMenuItem(title: title, action: #selector(MainWindow.sortOrder(_:)), keyEquivalent: "")
            it.tag = tag
            it.representedObject = kind
            m.addItem(it)
        }
        return m
    }

    /// The first nine notes' names beside ⌘1…⌘9; an item with no note under it is not shown.
    func refreshNotes() {
        guard let lib = (NSApp.delegate as? App)?.library else { return }
        for (i, it) in noteItems.enumerated() {
            if i < lib.notes.count {
                it.title = MainWindow.shown(lib.notes[i].title)
                it.isHidden = false
            } else {
                it.title = ""
                it.isHidden = true
            }
        }
        // The separator under them goes with them.
        if let sep = noteItems.last.flatMap({ windowMenu.items.firstIndex(of: $0) }).map({ windowMenu.items[$0 + 1] }) {
            sep.isHidden = lib.notes.isEmpty
        }
    }
}
