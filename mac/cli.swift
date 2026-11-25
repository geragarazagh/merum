// merum-cli: the notes from a terminal or a language model, no window (dev/rules.md, section 3, «Agent-native»).
// Run as merum-cli (a symlink to Merum.app/Contents/MacOS/Merum, wherever it lies) or as Merum with a command:
//
//   merum-cli list [--json]          the notes in the app's order: number, name, characters
//   merum-cli cat <name or number>   one note's text, exactly as stored
//   merum-cli new [NAME] < text      a new note from standard input (the default name unless NAME is given)
//   merum-cli status [--json]        version, whether the app runs, where the notes are, how many
//   merum-cli --version | --help
//
// While the app runs every command goes through it (a Mach port, CommandServer), so the CLI reads what is on screen,
// unsaved typing included, and a new note is made by the app itself: nothing writes the store behind its back. When it
// does not run, the CLI reads and writes the store with the same core code the app uses.
import AppKit

let cliName = "merum-cli"
private let portName = "com.geragaraza.merum.cli" as CFString

/// The app bundle this binary belongs to, found through the real executable path: run by name from PATH (a symlink)
/// argv[0] is the bare name.
let appBundle: Bundle = {
    let real = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let appURL = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: appURL) ?? .main
}()

/// Launched as its own app or launchd job (Finder, the Dock, Open at Login), not by a terminal or script.
private func answersForItself() -> Bool {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    let me = getpid()
    if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
        let r = unsafeBitCast(f, to: Lookup.self)(me)
        if r > 0 { return r == me }
    }
    return getppid() == 1
}

private func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

private func emit(_ data: Data) -> Never {
    FileHandle.standardOutput.write(data)
    exit(0)
}

private let usage = """
Usage: \(cliName) list [--json]
       \(cliName) cat <name or number>
       \(cliName) new [NAME] < text
       \(cliName) status [--json]
       \(cliName) --version | --help

Numbers are the notes' places in the app's list, from 1.
"""

/// Flags the app itself takes; anything else that starts with -- is refused without a window.
#if TRIALS
let guiFlags: Set<String> = ["--background", "--login", "--data", "--trial", "--trace"]
#else
let guiFlags: Set<String> = ["--background", "--login"]
#endif

// MARK: the commands, the same in the app and in the CLI

enum Command: Int32 {
    case list = 1, cat, new, status, show
}

@MainActor enum Commands {
    static func json(_ o: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func list(_ lib: Library) -> Data {
        let fmt = ISO8601DateFormatter()
        return json(lib.notes.enumerated().map { i, n in
            ["number": i + 1, "name": n.title, "characters": n.storage.length, "id": n.id.uuidString,
             "created": fmt.string(from: n.created), "modified": fmt.string(from: n.modified)] as [String: Any]
        })
    }

    /// A number is a place in the list; otherwise the exact name, then the name in any case.
    static func find(_ lib: Library, _ sel: String) -> Note? {
        if let i = Int(sel), i >= 1, i <= lib.notes.count, sel.allSatisfy(\.isNumber) { return lib.notes[i - 1] }
        return lib.notes.first { $0.title == sel } ?? lib.notes.first { $0.title.caseInsensitiveCompare(sel) == .orderedSame }
    }

    /// A new note with the text, last in the manual order. Returns its name. Not opened: the person's window stays on
    /// what it shows.
    static func new(_ lib: Library, text: String, name: String?) -> String {
        let n = lib.newNote()
        if let name, !name.isEmpty { lib.rename(n, to: name) }
        if !text.isEmpty { n.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text) }
        return n.title
    }

    static func status(_ lib: Library, running: Bool) -> [String: Any] {
        ["version": appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         "running": running,
         "notesFolder": (lib.store?.dir ?? Store.defaultDirectory).path,
         "notes": lib.notes.count,
         "sort": lib.sort.rawValue + (lib.sort == .manual ? "" : lib.ascending ? " ascending" : " descending"),
         "textSize": lib.textSize]
    }
}

/// In the app: answers merum-cli on a local Mach port.
@MainActor final class CommandServer {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private static weak var app: App?

    init(app: App) {
        Self.app = app
        var context = CFMessagePortContext()
        port = CFMessagePortCreateLocal(nil, portName, { _, msgid, data, _ in
            let input = data.map { $0 as Data } ?? Data()
            let out: Data = MainActor.assumeIsolated { CommandServer.handle(msgid, input) }
            return Unmanaged.passRetained(out as CFData)
        }, &context, nil)
        if let port {
            source = CFMessagePortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// First byte 0: the payload follows; 1: an error message follows.
    private static func handle(_ id: Int32, _ input: Data) -> Data {
        guard let app, let cmd = Command(rawValue: id) else { return Data([1]) + Data("Unknown command.".utf8) }
        let lib = app.library
        switch cmd {
        case .list: return Data([0]) + Commands.list(lib)
        case .cat:
            let sel = String(decoding: input, as: UTF8.self)
            guard let n = Commands.find(lib, sel) else { return Data([1]) + Data("No note \(sel).".utf8) }
            return Data([0]) + Store.utf8(n.textSnapshot)
        case .new:
            let parts = input.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.first.map { String(decoding: $0, as: UTF8.self) }
            let text = parts.count > 1 ? String(decoding: parts[1], as: UTF8.self) : ""
            let title = Commands.new(lib, text: text, name: name)
            lib.flush()
            return Data([0]) + Data(title.utf8)
        case .status: return Data([0]) + Commands.json(Commands.status(lib, running: true))
        case .show:
            app.show()
            return Data([0])
        }
    }

    /// From the CLI: the running app's answer, or nil when no app answers.
    nonisolated static func send(_ cmd: Command, _ data: Data = Data()) -> Data? {
        guard let remote = CFMessagePortCreateRemote(nil, portName) else { return nil }
        var reply: Unmanaged<CFData>?
        // A new note of 10 M characters takes the app a moment; ten minutes is the outer limit of a hung app.
        let r = CFMessagePortSendRequest(remote, cmd.rawValue, data as CFData, 10, 600, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard r == kCFMessagePortSuccess, let d = reply?.takeRetainedValue() as Data? else { return nil }
        return d
    }
}

/// Handles a CLI invocation and exits; returns false when the arguments are the app's own (launch the GUI).
@MainActor func runCLI(_ raw: [String]) -> Bool {
    let exe = appBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Merum"
    let named = URL(fileURLWithPath: raw[0]).lastPathComponent != exe
    // macOS and Xcode may pass their own single-dash arguments (-psn_…, -NSDocumentRevisionsDebugMode YES): not ours.
    let rest = Array(raw.dropFirst()).filter { !$0.hasPrefix("-psn_") }
    guard let cmd = rest.first, !(cmd.hasPrefix("-") && !cmd.hasPrefix("--")) else {
        if named { print(usage); exit(0) }
        return false
    }
    switch cmd {
    case "--help", "-h", "help": print(usage); exit(0)
    case "--version", "-V":
        let v = appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let n = appBundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Merum"
        print("\(n) \(v)"); exit(0)
    case "list", "cat", "new", "status": break
    default:
        if named || !guiFlags.contains(cmd) { fail(usage) }
        // The app's own flags: anything after them must be known too.
        for a in rest where a.hasPrefix("--") && !guiFlags.contains(a) { fail(usage) }
        return false
    }
    if answersForItself() { fail("\(cliName) runs from a terminal or script, not launched as an app or launchd job.") }
    let tail = Array(rest.dropFirst())

    func ask(_ c: Command, _ d: Data = Data()) -> Data? {
        guard let r = CommandServer.send(c, d), let first = r.first else { return nil }
        let payload = r.dropFirst()
        if first != 0 { fail(String(decoding: payload, as: UTF8.self)) }
        return Data(payload)
    }
    // Not running: the store as the app would read it (no sync, nothing written but a new note).
    func offline() -> Library {
        if !FileManager.default.fileExists(atPath: Store.defaultDirectory.appendingPathComponent("notes.json").path) && cmd != "new" {
            return Library(store: nil)
        }
        return Library(store: Store())
    }

    switch cmd {
    case "list":
        guard tail.isEmpty || tail == ["--json"] else { fail(usage) }
        let data = ask(.list) ?? Commands.list(offline())
        if tail == ["--json"] { emit(data + Data("\n".utf8)) }
        let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        for i in items { print("\(i["number"] ?? "")\t\(i["name"] ?? "")\t\(i["characters"] ?? 0)") }
        exit(0)
    case "cat":
        guard tail.count == 1 else { fail(usage) }
        if let d = ask(.cat, Data(tail[0].utf8)) { emit(d) }
        let lib = offline()
        guard let n = Commands.find(lib, tail[0]) else { fail("No note \(tail[0]).") }
        emit(Store.utf8(n.textSnapshot))
    case "new":
        guard tail.count <= 1, !(tail.first?.hasPrefix("--") ?? false) else { fail(usage) }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard String(data: input, encoding: .utf8) != nil else { fail("The text is not UTF-8.") }
        let name = tail.first ?? ""
        if let d = ask(.new, Data(name.utf8) + Data([0]) + input) { print(String(decoding: d, as: UTF8.self)); exit(0) }
        let lib = Library(store: Store())
        let title = Commands.new(lib, text: String(decoding: input, as: UTF8.self), name: name)
        lib.flush()
        print(title)
        exit(0)
    case "status":
        guard tail.isEmpty || tail == ["--json"] else { fail(usage) }
        var s: [String: Any]
        if let d = ask(.status), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { s = o } else {
            s = Commands.status(offline(), running: false)
        }
        if tail == ["--json"] { emit(Commands.json(s) + Data("\n".utf8)) }
        for k in ["version", "running", "notesFolder", "notes", "sort", "textSize"] {
            let v = s[k].map { "\($0)" } ?? ""
            print("\(k): \(k == "running" ? ((s[k] as? Bool) == true ? "yes" : "no") : v)")
        }
        exit(0)
    default:
        fail(usage)
    }
}
