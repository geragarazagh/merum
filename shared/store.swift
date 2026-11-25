// The notes on disk, in one removable folder:
//   notes.json      the list (titles, dates, order), the sort, the text size, the note last open
//   Notes/<id>.txt  each note's text, UTF-8, readable by any editor
//   sync.json       CloudKit's state (Sync)
//   Base/<id>.txt   for a note with edits not yet in iCloud, its text as last synced: the base of the three-way merge
//                   if another device changed it meanwhile, kept across a quit (deleted once the upload lands)
// Nothing else is written anywhere.
//
// Writes are debounced (one second after the first change of a burst, so a long run of typing is saved every second),
// atomic (a whole new file renamed over the old one) and done on a background queue from immutable copies of the texts
// taken on the main thread (~1 ms per 10 M characters). flush() writes what is pending and waits: on hide, background
// and quit. Order inside a write, so a crash at any point loses nothing: texts first, then notes.json (which names the
// notes being removed), then the removed notes' files. On load a text file the list does not name is a note whose list
// entry never got written and is kept; one the list names as removed is deleted.
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What Sync keeps through the store.
@MainActor protocol SyncPersisting: AnyObject {
    func syncStateData() -> Data
    func base(for id: UUID) -> NSString?
}

@MainActor final class Store {
    let dir: URL
    weak var library: Library?
    weak var syncSource: SyncPersisting?
    /// Seconds from the first change to the write.
    var delay: TimeInterval = 1

    struct Loaded {
        var notes: [Note] = []
        var sort: Library.Sort = .manual
        var ascending = true
        var textSize = 100
        var settingsModified: Double = 0
        var lastOpen: UUID?
        /// Notes the list names whose text file is missing: Sync fetches their text again from iCloud.
        var missingText: [UUID] = []
        /// The list on disk was broken, incomplete or named notes being removed: it is written again.
        var repaired = false
    }

    private var texts: Set<UUID> = []
    private var removals: Set<UUID> = []
    private var bases: Set<UUID> = []
    private var meta = false
    private var syncState = false
    private var timer: DispatchWorkItem?
    private let queue = DispatchQueue(label: "merum.store", qos: .utility)
    private(set) var missingText: [UUID] = []

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Merum")
    }

    init(dir: URL = Store.defaultDirectory) {
        self.dir = dir
    }

    private var notesDir: URL { dir.appendingPathComponent("Notes") }
    private var baseDir: URL { dir.appendingPathComponent("Base") }
    private var metaURL: URL { dir.appendingPathComponent("notes.json") }
    private var syncURL: URL { dir.appendingPathComponent("sync.json") }
    private func textURL(_ id: UUID) -> URL { notesDir.appendingPathComponent(id.uuidString + ".txt") }
    private func baseURL(_ id: UUID) -> URL { baseDir.appendingPathComponent(id.uuidString + ".txt") }

    // MARK: marking

    func noteChanged(_ id: UUID) { texts.insert(id); removals.remove(id); meta = true; schedule() }
    func noteMetaChanged(_ id: UUID) { meta = true; schedule() }
    func metaChanged() { meta = true; schedule() }
    /// Back by undo: its file is still on disk if the removal has not been written yet, and is then left as it is
    /// (⌘Z right after ⌘A ⌘⌫ rewrites nothing); else it is written again.
    func noteRestored(_ id: UUID) {
        let waitedToBeWritten = unwritten.remove(id) != nil
        if removals.remove(id) == nil || waitedToBeWritten { texts.insert(id) }
        meta = true; schedule()
    }
    func noteRemoved(_ id: UUID) {
        if texts.remove(id) != nil { unwritten.insert(id) }   // its last edit was not on disk yet
        removals.insert(id); meta = true; schedule()
    }
    private var unwritten: Set<UUID> = []
    func syncChanged() { syncState = true; schedule() }
    func baseChanged(_ id: UUID) { bases.insert(id); schedule() }

    private func schedule() {
        guard timer == nil else { return }
        let t = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.write(wait: false) } }
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: t)
    }

    /// Writes everything pending and returns when it is on disk.
    func flush() { write(wait: true) }

    // MARK: writing

    /// Immutable copies only, handed to the write queue.
    private struct Job: @unchecked Sendable {
        var texts: [(UUID, NSString)] = []
        var bases: [(UUID, NSString?)] = []
        var meta: Data?
        var removals: [UUID] = []
        var sync: Data?
    }

    private func write(wait: Bool) {
        timer?.cancel(); timer = nil
        var job = Job()
        if let library {
            job.texts = texts.compactMap { id in library.note(id: id).map { (id, $0.textSnapshot) } }
            if meta || !removals.isEmpty { job.meta = metaData(library, removing: removals) }
        }
        job.removals = Array(removals)
        job.bases = bases.map { ($0, syncSource?.base(for: $0)) }
        if syncState { job.sync = syncSource?.syncStateData() }
        unwritten.subtract(removals)
        texts = []; removals = []; bases = []; meta = false; syncState = false
        let run: @Sendable () -> Void = { [dir, notesDir, baseDir, metaURL, syncURL, job] in
            let fm = FileManager.default
            for d in [dir, notesDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            for (id, s) in job.texts {
                let url = notesDir.appendingPathComponent(id.uuidString + ".txt")
                try? Store.utf8(s).write(to: url, options: .atomic)
            }
            for (id, s) in job.bases {
                let url = baseDir.appendingPathComponent(id.uuidString + ".txt")
                if let s {
                    try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
                    try? Store.utf8(s).write(to: url, options: .atomic)
                } else {
                    try? fm.removeItem(at: url)
                }
            }
            if let m = job.meta { try? m.write(to: metaURL, options: .atomic) }
            for id in job.removals { try? fm.removeItem(at: notesDir.appendingPathComponent(id.uuidString + ".txt")) }
            if let s = job.sync { try? s.write(to: syncURL, options: .atomic) }
        }
        if wait { queue.sync(execute: run) } else { queue.async(execute: run) }
    }

    nonisolated static func utf8(_ s: NSString) -> Data {
        s.data(using: String.Encoding.utf8.rawValue) ?? Data((s as String).utf8)
    }

    private func metaData(_ library: Library, removing: Set<UUID>) -> Data {
        let list: [[String: Any]] = library.notes.map { n in
            ["id": n.id.uuidString, "title": n.title, "created": n.created.timeIntervalSince1970,
             "modified": n.modified.timeIntervalSince1970, "position": n.position, "renamed": n.renamed, "pinned": n.pinned]
        }
        var root: [String: Any] = ["version": 1, "sort": library.sort.rawValue, "ascending": library.ascending,
                                   "textSize": library.textSize, "settingsModified": library.settingsModified, "notes": list,
                                   "removing": removing.map(\.uuidString)]
        if let open = library.lastOpen { root["lastOpen"] = open.uuidString }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    // MARK: loading

    /// Reads everything. A broken notes.json or a broken entry costs only titles and order: every text file still
    /// becomes a note. A text that is not valid UTF-8 is read with U+FFFD in place of the bad bytes.
    func load() -> Loaded {
        var out = Loaded()
        let fm = FileManager.default
        let root = (try? Data(contentsOf: metaURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let s = root["sort"] as? String, let sort = Library.Sort(rawValue: s) { out.sort = sort }
        if let a = root["ascending"] as? Bool { out.ascending = a }
        if let t = root["textSize"] as? Int { out.textSize = Library.closestTextSize(t) }
        if let t = root["settingsModified"] as? Double, t.isFinite { out.settingsModified = t }
        out.lastOpen = (root["lastOpen"] as? String).flatMap(UUID.init(uuidString:))
        let removing = Set(((root["removing"] as? [String]) ?? []).compactMap(UUID.init(uuidString:)))
        out.repaired = !removing.isEmpty || (root.isEmpty && fm.fileExists(atPath: metaURL.path))

        struct Entry { var id: UUID; var title: String?; var created: Date?; var modified: Date?; var position: Double?; var renamed: Bool; var pinned = false }
        var entries: [Entry] = []
        var listed = Set<UUID>()
        for e in (root["notes"] as? [Any]) ?? [] {
            guard let d = e as? [String: Any], let id = (d["id"] as? String).flatMap(UUID.init(uuidString:)),
                  !listed.contains(id), !removing.contains(id) else { continue }
            listed.insert(id)
            func date(_ k: String) -> Date? { (d[k] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } }
            entries.append(Entry(id: id, title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 created: date("created"), modified: date("modified"),
                                 position: (d["position"] as? Double).flatMap { $0.isFinite ? $0 : nil },
                                 renamed: d["renamed"] as? Bool ?? false, pinned: d["pinned"] as? Bool ?? false))
        }
        // Files the list does not name.
        let files = (try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? []
        for f in files where f.pathExtension == "txt" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
            if removing.contains(id) { try? fm.removeItem(at: f); continue }
            guard !listed.contains(id) else { continue }
            let v = try? f.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            entries.append(Entry(id: id, title: nil, created: v?.creationDate, modified: v?.contentModificationDate, position: nil, renamed: false))
            listed.insert(id)
            out.repaired = true
        }
        // Texts are decoded in parallel: ~37 ms for 10 M characters each, on as many cores as there are notes.
        let urls = entries.map { textURL($0.id) }
        let slots = Slots(urls.count)
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            // Each iteration writes only its own slot.
            guard let data = try? Data(contentsOf: urls[i]) else { slots.missing[i] = true; return }
            slots.texts[i] = Store.decode(data)
        }
        let decoded = slots.texts, missing = slots.missing
        var maxPosition = entries.compactMap(\.position).max() ?? 0
        let now = Date()
        for (i, e) in entries.enumerated() {
            if missing[i] { out.missingText.append(e.id) }
            let storage = NSTextStorage(string: (decoded[i] ?? "") as String)
            let position: Double
            if let p = e.position { position = p } else { maxPosition += 1; position = maxPosition }
            out.notes.append(Note(id: e.id, title: e.title ?? "", created: e.created ?? e.modified ?? now,
                                  modified: e.modified ?? e.created ?? now, position: position,
                                  renamed: e.title != nil && e.renamed, pinned: e.pinned, storage: storage))
        }
        // Default names for notes whose list entry was lost, the lowest free ones, oldest first.
        var taken = Set(out.notes.map(\.title))
        var k = 1
        for n in out.notes.sorted(by: { $0.created < $1.created }) where n.title.isEmpty {
            while taken.contains(Ordinal.noteName(k)) { k += 1 }
            n.title = Ordinal.noteName(k); taken.insert(n.title)
        }
        missingText = out.missingText
        return out
    }

    private final class Slots: @unchecked Sendable {
        var texts: [NSString?]
        var missing: [Bool]
        init(_ n: Int) { texts = Array(repeating: nil, count: n); missing = Array(repeating: false, count: n) }
    }

    nonisolated static func decode(_ data: Data) -> NSString {
        // NSString straight from UTF-8: a text storage made from it takes 2 ms for 10 M characters, against 57 ms
        // from a Swift String, which must first be converted to UTF-16 (measured).
        if let s = NSString(data: data, encoding: String.Encoding.utf8.rawValue) { return s }
        return String(decoding: data, as: UTF8.self) as NSString
    }

    /// What Sync stored, and the bases of notes with unsynced edits.
    func loadSync() -> (state: Data?, bases: [UUID: NSString]) {
        let state = try? Data(contentsOf: syncURL)
        var bases: [UUID: NSString] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), let d = try? Data(contentsOf: f) else { continue }
            bases[id] = Store.decode(d)
        }
        return (state, bases)
    }
}
