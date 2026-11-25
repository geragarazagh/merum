// The clipboard every copy, cut and paste of the app goes through: the system's, except in a trial build, where checks
// run against a private one so they never touch the person's clipboard (trial.swift).
import AppKit

@MainActor enum Clipboard {
    static var board: NSPasteboard = .general
}
