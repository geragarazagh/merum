// The app's two actions for the system: App Shortcuts (Shortcuts, Spotlight, Siri, Action button → Shortcut) and the
// controls (Action button → Controls, Control Center, the Lock Screen).
//
// Compiled into the app and into the controls extension: a control's intent must belong to both, or pressing it does
// nothing (WidgetKit, «Creating controls to perform actions across the system»). Both run in the app, in front, so only
// the app's copy does the work; the extension's copy (MERUM_CONTROLS) only names them.
//
// Each is an OpenIntent, the form Apple's control guide names for a button that opens its app, with a one-case target
// («Last Note», «New Note») that is its default, so nothing is ever asked. Measured on the simulator 2026-11-27: a cold
// launch from a control came forward in 7-11 s this way, and in 11 s or not within 9 s as a plain AppIntent with
// supportedModes .foreground; warm presses were the same. As an App Shortcut on Action button → Shortcut, every form
// (Apple's own Open App included) ran through the system's shortcut interface there; on Action button → Controls the
// island shows only the control's symbol for ~0.7 s.
import AppIntents

/// Where Open Merum lands: the one place, the note open last.
enum LastNote: String, AppEnum {
    case last
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static let caseDisplayRepresentations: [LastNote: DisplayRepresentation] = [
        .last: DisplayRepresentation(title: "Last Note", image: .init(systemName: "note.text")),
    ]
}

/// Where New Note lands: a note made for it.
enum FreshNote: String, AppEnum {
    case new
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static let caseDisplayRepresentations: [FreshNote: DisplayRepresentation] = [
        .new: DisplayRepresentation(title: "New Note", image: .init(systemName: "square.and.pencil")),
    ]
}

/// Merum on the note open last, keyboard up, caret at the end; pressed while Merum is open, the note stays.
struct OpenMerumIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Merum"
    static let description = IntentDescription("Opens the last note, ready to type.")

    @Parameter(title: "Note", default: .last) var target: LastNote

    @MainActor func perform() async throws -> some IntentResult {
        #if !MERUM_CONTROLS
        Merum.shared.model.arrive(.last)
        #endif
        return .result()
    }
}

/// A new note on every run, keyboard up; an empty note left behind goes by the core's usual rule (Library.leave).
struct NewNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Creates a note in Merum, ready to type.")

    @Parameter(title: "Note", default: .new) var target: FreshNote

    @MainActor func perform() async throws -> some IntentResult {
        #if !MERUM_CONTROLS
        Merum.shared.model.arrive(.new)
        #endif
        return .result()
    }
}
