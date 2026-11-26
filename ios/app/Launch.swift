// The App Shortcuts the app offers, and what its two actions do once Merum is in front (intents/Actions.swift).
import AppIntents
import UIKit

/// Listed under Merum in Shortcuts, Spotlight, Siri and Action button → Shortcut, with no Shortcut built by hand.
/// Symbols: the app's own «No Notes» picture for Open (an App Shortcut takes an SF Symbol, never the app icon), and
/// the compose symbol the app's New Note buttons carry.
struct MerumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenMerumIntent(),
                    phrases: ["Open \(.applicationName)", "Show my \(.applicationName) note"],
                    shortTitle: "Open Merum", systemImageName: "note.text")
        AppShortcut(intent: NewNoteIntent(),
                    phrases: ["New \(.applicationName) note", "New note in \(.applicationName)",
                              "Make a note in \(.applicationName)"],
                    shortTitle: "New Note", systemImageName: "square.and.pencil")
    }
}

extension Model {
    enum Arrival { case last, new }

    /// The editor in front, the keyboard up and the caret at the end: of the note open last, or of a new note. Over
    /// whatever was on screen: the list, a selection, a share sheet or an alert.
    func arrive(_ arrival: Arrival) {
        selecting = false
        editors.container.window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        switch arrival {
        case .new:
            compose()
        case .last:
            if path.isEmpty {
                if let n = open { show(n) } else { path = [.editor] }
            }
        }
        editors.focusNext = true
        editors.caretToEnd = true
        editors.showCurrent()
    }
}

/// iOS hands an intent that brings the app forward to a scene first, and with a scene delegate that does not adopt
/// this protocol it fails the hand-over (UISceneConnectionOptionDefinitionError.nonConformingDelegate in the log) and a
/// cold launch stayed in the background. The work itself is the intent's perform(), which follows.
extension SceneDelegate: AppIntentSceneDelegate {
    func scene(_ scene: UIScene, willPerformAppIntent appIntent: any UISceneAppIntent) {}
}
