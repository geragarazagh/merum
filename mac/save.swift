// ⌘S: the open note as «<name>.txt», UTF-8. Settings > Save To decides where: Ask Each Time (a save panel on the
// window) or one folder chosen once, where a name already taken gets « 2», « 3» as Finder names a copy.
import AppKit
import UniformTypeIdentifiers

@MainActor enum Saver {
    /// The folder chosen once, or nil for Ask Each Time.
    static var folder: URL? {
        get { UserDefaults.standard.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "saveFolder") }
    }

    /// The note's name as a file name: «/» and «:» are the only characters macOS refuses in a name; a leading dot would
    /// hide the file.
    static func fileName(_ title: String) -> String {
        var s = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "Note" }
        // APFS takes 255 UTF-8 bytes; the suffix « 99.txt» needs 7.
        while s.utf8.count > 240 { s.removeLast() }
        return s
    }

    /// «Name.txt», else «Name 2.txt», «Name 3.txt»…
    static func freeURL(in dir: URL, for title: String) -> URL {
        let base = fileName(title)
        let fm = FileManager.default
        var url = dir.appendingPathComponent(base + ".txt")
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(i).txt")
            i += 1
        }
        return url
    }

    static func save(_ note: Note, from window: NSWindow) {
        let text = note.textSnapshot
        if let dir = folder, FileManager.default.fileExists(atPath: dir.path) {
            write(text, to: freeURL(in: dir, for: note.title), window: window)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(note.title) + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { write(text, to: url, window: window) }
        }
    }

    private static func write(_ text: NSString, to url: URL, window: NSWindow) {
        do {
            try Store.utf8(text).write(to: url, options: .atomic)
        } catch {
            let a = NSAlert()
            a.messageText = "The note could not be saved."
            a.informativeText = "\(url.path): \(error.localizedDescription)"
            a.beginSheetModal(for: window)
        }
    }
}
