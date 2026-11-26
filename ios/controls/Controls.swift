// Merum's controls: buttons people place on the Action button, in Control Center or on the Lock Screen (nothing is
// placed by itself). Each runs one of the app's two intents (intents/Actions.swift), which open the app.
import AppIntents
import SwiftUI
import WidgetKit

@main struct MerumControls: WidgetBundle {
    var body: some Widget {
        OpenMerumControl()
        NewNoteControl()
    }
}

struct OpenMerumControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.geragaraza.merum.controls.open") {
            ControlWidgetButton(action: OpenMerumIntent()) {
                Label("Open Merum", systemImage: "note.text")
            }
        }
        .displayName("Open Merum")
        .description("Opens the last note, ready to type.")
    }
}

struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.geragaraza.merum.controls.new") {
            ControlWidgetButton(action: NewNoteIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Creates a note in Merum, ready to type.")
    }
}
