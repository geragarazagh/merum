// The app's two actions for the system: App Shortcuts (Shortcuts, Spotlight, Siri, Action button → Shortcut) and the
// controls (Action button → Controls, Control Center, the Lock Screen).
//
// Compiled into the app and into the controls extension: a control's intent must belong to both, or pressing it does
// nothing (WidgetKit, «Creating controls to perform actions across the system»). Both run in the app, in front
// (supportedModes), so only the app's copy does the work; the extension's copy (MERUM_CONTROLS) only names them.
import AppIntents

/// Merum on the note open last, keyboard up, caret at the end; pressed while Merum is open, the note stays.
struct OpenMerumIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Merum"
    static let description = IntentDescription("Opens the last note, ready to type.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor func perform() async throws -> some IntentResult {
        #if !MERUM_CONTROLS
        Merum.shared.model.arrive(.last)
        #endif
        return .result()
    }
}

/// A new note on every run, keyboard up; an empty note left behind goes by the core's usual rule (Library.leave).
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Creates a note in Merum, ready to type.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor func perform() async throws -> some IntentResult {
        #if !MERUM_CONTROLS
        Merum.shared.model.arrive(.new)
        #endif
        return .result()
    }
}
