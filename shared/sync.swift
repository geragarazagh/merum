// Notes through iCloud: CloudKit's private database, zone «Notes», one record «Note» per note (recordName = the note's
// id). Plain CloudKit operations, not CKSyncEngine, which needs macOS 14.
//
// - Local first: every edit is on disk here before it goes anywhere; with no account or no network nothing changes for
//   the person, and the queue (which notes changed, which were deleted) waits in sync.json until it can go.
// - Up: a note's text and fields go a moment after the last edit (1.5 s; 5 s for a text over half a megabyte, which
//   travels as a file), deletes likewise. Down: a silent push on the zone, and a fetch at launch and whenever the
//   window is shown or the app comes forward (`fetchNow`), with the zone's change token kept between runs.
// - Applying: a change from another device replaces only what differs (common start and end kept), so the caret and
//   scroll of the open note stay; that note's text steps leave the undo history.
// - Conflicts never lose text: a note changed here and elsewhere since the last sync is merged three ways against the
//   text as last synced (Base/<id>.txt while it matters). Fields other than the text: the side that did not change
//   them takes the other's. A note deleted on one device and edited on the other stays, with the edits.
// - Errors: an expired token fetches everything again; a missing zone (deleted from iCloud settings) is made again and
//   every note goes up again; rate limits wait the time CloudKit names; network errors back off up to 5 minutes; a
//   batch too large is halved; another iCloud account signed in starts over against that account, the notes here
//   staying and going up to it.
//
// Everything CloudKit-specific sits behind `CloudDatabase`, so the logic runs in tests against an in-memory server.
import CloudKit
import Foundation
#if os(macOS)
import AppKit
import Security
#else
import UIKit
#endif

// MARK: the seam

/// A note as a record: fields, text and CloudKit's own system fields (opaque `meta`, with `tag` its change tag).
struct CloudNote {
    var id: UUID
    var title: String
    var created: Date
    var modified: Date
    var position: Double
    var renamed: Bool
    /// Records made before pinning existed have no field: unpinned.
    var pinned = false
    /// Going up: nil leaves the text on the server as it is (only fields changed). Coming down: nil when the text's
    /// file did not come with the record (then the record is fetched again on its own).
    var text: NSString?
    var meta: Data?
    var tag: String?
}

enum CloudError: Error, Equatable {
    case tokenExpired
    case zoneNotFound
    case notAuthenticated
    case quotaExceeded
    case limitExceeded
    /// Try again after so many seconds (rate limits, busy zone, unavailable service, network).
    case retryAfter(Double)
    case other(String)
}

enum CloudAccount: Equatable {
    case available(userID: String)
    case none
    /// Restricted, temporarily unavailable or not determined: wait for the account to change.
    case unavailable
}

struct ZoneChanges {
    var changed: [CloudNote] = []
    var deleted: [UUID] = []
    var token: Data?
    var more = false
}

enum SaveOutcome {
    case saved(meta: Data?, tag: String?)
    /// The server has a newer version (serverRecordChanged).
    case conflict(server: CloudNote)
    /// The record is gone from the server (unknownItem) though this device had its system fields.
    case gone
    case failed(CloudError)
}

protocol CloudDatabase: AnyObject {
    func account() async -> CloudAccount
    func ensureZone() async throws
    func ensureSubscription() async throws
    func fetchChanges(since token: Data?) async throws -> ZoneChanges
    /// The current records for these ids; an id with no record is absent from the result.
    func fetch(_ ids: [UUID]) async throws -> [UUID: CloudNote]
    func modify(save: [CloudNote], delete: [UUID]) async throws -> (saved: [UUID: SaveOutcome], deleted: [UUID: CloudError?])
}

// MARK: the engine

@MainActor final class Sync: SyncPersisting {
    let library: Library
    let db: CloudDatabase

    /// Seconds from an edit to its upload: a small text goes almost at once; a big one (a file each time) waits for
    /// a pause in typing.
    var delay: Double = 1.5
    var bigDelay: Double = 5
    /// Bytes of UTF-8 under which a text travels inside the record (a record holds at most 1 MB); above, as a file.
    nonisolated static let inlineLimit = 500_000

    // Kept in sync.json.
    private var token: Data?
    private var metas: [UUID: Data] = [:]
    private var tags: [UUID: String] = [:]
    private var dirtyText: Set<UUID> = []
    private var dirtyFields: Set<UUID> = []
    private var deletes: Set<UUID> = []
    private var zoneReady = false
    private var subscribed = false
    private var userID: String?
    /// The text as last synced, for notes with edits not yet up (Base/<id>.txt).
    private var bases: [UUID: NSString] = [:]

    // In memory only.
    private var edits: [UUID: Int] = [:]
    private var missing: Set<UUID> = []
    private var running = false
    private var again = false
    private var fetchWanted = true
    private var timer: Task<Void, Never>?
    private var timerDue: Date?
    private var backoff: Double = 0
    private var paused = false   // no account: waits for one
    private var observer: NSObjectProtocol?

    /// Fired after each run, for tests and for the UI if it ever wants it: nil when everything went, else the error
    /// that stopped the run.
    var onRunEnded: ((CloudError?) -> Void)?

    init(library: Library, database: CloudDatabase) {
        self.library = library
        db = database
    }

    /// Starts syncing: loads the state, hooks into the library and runs once (fetch, then upload what waits).
    /// Sync talks to iCloud only for the real notes folder (Store.defaultDirectory). A copy started on another folder
    /// (a test run on a scratch folder) would fetch the person's notes into it and send its test deletions back to
    /// every device; it syncs only when this is set on purpose.
    var anyFolder = false

    /// Whether `start` found a folder it may sync.
    private(set) var started = false

    func start() {
        if let dir = library.store?.dir, !anyFolder,
           dir.standardizedFileURL.resolvingSymlinksInPath() != Store.defaultDirectory.standardizedFileURL.resolvingSymlinksInPath() {
            return
        }
        started = true
        library.sync = self
        library.store?.syncSource = self
        if let store = library.store {
            let (state, bases) = store.loadSync()
            if let state { restore(state) }
            self.bases = bases
            missing = Set(store.missingText)
        }
        // A note in the list that never reached iCloud (first launch with sync, or made before an account existed).
        for n in library.notes where metas[n.id] == nil { dirtyText.insert(n.id); dirtyFields.insert(n.id) }
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountChanged() }
        }
        kick(fetch: true)
    }

    /// The window was shown or the app came forward.
    func fetchNow() { guard started else { return }; kick(fetch: true) }

    /// The app is in front (the Mac window shown, the iPhone app active) or not. In front it fetches at once and then
    /// every 15 s, since silent pushes are throttled by the system and once took over 90 s to come; behind, pushes and
    /// the next time in front bring changes.
    func setForeground(_ on: Bool) {
        poll?.cancel(); poll = nil
        guard on, started else { return }
        fetchNow()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 15) * 1e9))
                guard !Task.isCancelled, let self else { return }
                self.fetchNow()
            }
        }
    }
    /// Seconds between fetches while in front.
    var pollInterval: Double = 15
    private var poll: Task<Void, Never>?

    /// A remote notification; true when it was this zone's and a fetch started.
    @discardableResult func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let n = CKNotification(fromRemoteNotificationDictionary: userInfo), n.subscriptionID == CloudKitDatabase.subscriptionID else { return false }
        kick(fetch: true)
        return true
    }

    private func accountChanged() { paused = false; kick(fetch: true) }

    /// Waiting work, for tests: nothing to send and nothing running.
    var idle: Bool { !running && dirtyText.isEmpty && dirtyFields.isEmpty && deletes.isEmpty && timer == nil }

    // MARK: from the library

    func localTextWillChange(_ note: Note) {
        // The text as last synced is the text now, before the first edit since the last upload.
        guard bases[note.id] == nil, !dirtyText.contains(note.id), metas[note.id] != nil else { return }
        bases[note.id] = note.textSnapshot
        library.store?.baseChanged(note.id)
    }

    func localTextChanged(_ note: Note) {
        dirtyText.insert(note.id)
        edits[note.id, default: 0] += 1
        changed(big: note.length > Sync.inlineLimit / 3)
    }

    func localFieldsChanged(_ note: Note) {
        dirtyFields.insert(note.id)
        edits[note.id, default: 0] += 1
        changed(big: false)
    }

    func localCreated(_ note: Note) {
        dirtyText.insert(note.id); dirtyFields.insert(note.id)
        changed(big: false)
    }

    func localDeleted(_ notes: [Note]) {
        // Its unsynced edits stay marked (upload skips notes not in the library): an undo before the delete has gone
        // leaves the record as it was and sends only what was waiting before.
        for n in notes {
            if metas[n.id] != nil { deletes.insert(n.id) } else { forgetPending(n.id) }   // never in iCloud: nothing to send
        }
        changed(big: false)
    }

    /// Back by undo: if its delete has not gone yet nothing needs to go (⌘Z right after ⌘A ⌘⌫ sends nothing, not
    /// even a 10 M-character text again); if it has, the note goes up as a new record.
    func localRestored(_ notes: [Note]) {
        for n in notes where deletes.remove(n.id) == nil {
            metas[n.id] = nil; tags[n.id] = nil
            dirtyText.insert(n.id); dirtyFields.insert(n.id)
        }
        changed(big: false)
    }

    private func changed(big: Bool) {
        library.store?.syncChanged()
        schedule(after: big ? bigDelay : delay)
    }

    // MARK: running

    private func kick(fetch: Bool) {
        if fetch { fetchWanted = true }
        schedule(after: 0)
    }

    /// Off in tests, which call `run()` themselves.
    var autorun = true

    /// One timer: an earlier due time replaces a later one, a later one waits for the earlier run.
    private func schedule(after seconds: Double) {
        guard autorun else { return }
        let due = Date().addingTimeInterval(seconds)
        if let d = timerDue, d <= due, timer != nil { return }
        timer?.cancel()
        timerDue = due
        timer = Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            guard !Task.isCancelled, let self else { return }
            self.timer = nil; self.timerDue = nil
            await self.run()
        }
    }

    func run() async {
        guard !running else { again = true; return }
        running = true
        var failure: CloudError?
        repeat {
            again = false
            do {
                try await pass()
                backoff = 0
            } catch let e as CloudError {
                failure = e
                handle(e)
            } catch {
                failure = .other("\(error)")
                handle(.other("\(error)"))
            }
        } while again && failure == nil
        running = false
        library.store?.syncChanged()
        onRunEnded?(failure)
    }

    private func pass() async throws {
        guard started else { return }
        guard !paused else { throw CloudError.notAuthenticated }
        switch await db.account() {
        case .available(let id):
            if let userID, userID != id { startOver() }
            userID = id
        case .none, .unavailable:
            paused = true
            throw CloudError.notAuthenticated
        }
        if !zoneReady { try await db.ensureZone(); zoneReady = true }
        if !subscribed {
            // No push only means changes come at the next fetch; it is tried again next time.
            do { try await db.ensureSubscription(); subscribed = true } catch {}
        }
        if fetchWanted {
            fetchWanted = false
            do { try await fetchChanges() } catch { fetchWanted = true; throw error }
        }
        if !missing.isEmpty { try await fetchMissing() }
        try await upload()
    }

    private func handle(_ e: CloudError) {
        switch e {
        case .tokenExpired:
            token = nil; fetchWanted = true; schedule(after: 0)
        case .zoneNotFound:
            startOver(); schedule(after: 0)
        case .notAuthenticated:
            break   // CKAccountChanged starts it again
        case .retryAfter(let s):
            schedule(after: max(s, 1))
        case .quotaExceeded:
            schedule(after: 600)
        case .limitExceeded, .other:
            backoff = min(max(backoff * 2, 5), 300)
            schedule(after: backoff)
        }
    }

    /// The zone or the account is new: nothing on the server is known, and every note here goes up.
    private func startOver() {
        token = nil; metas = [:]; tags = [:]; zoneReady = false; subscribed = false; deletes = []
        for id in bases.keys { library.store?.baseChanged(id) }
        bases = [:]
        for n in library.notes { dirtyText.insert(n.id); dirtyFields.insert(n.id) }
        fetchWanted = true
    }

    // MARK: down

    private func fetchChanges() async throws {
        repeat {
            let page: ZoneChanges
            do { page = try await db.fetchChanges(since: token) }
            catch CloudError.tokenExpired { token = nil; continue }
            for r in page.changed { await receive(r) }
            try await receiveDeletions(page.deleted.filter { id in !page.changed.contains { $0.id == id } })
            token = page.token
            library.store?.syncChanged()
            if !page.more { break }
        } while true
    }

    private func fetchMissing() async throws {
        let ids = Array(missing)
        let found = try await db.fetch(ids)
        // An id with no record is dropped; a record whose text still does not come is asked for again next run.
        missing = Set(ids.filter { found[$0] != nil && found[$0]?.text == nil })
        for r in found.values where r.text != nil { await receive(r) }
    }

    /// A record from the server: a new note, a change to one, or this device's own upload coming back.
    func receive(_ r: CloudNote) async {
        let knownTag = tags[r.id]
        guard let remote = r.text else {
            // Never applied without its text: an empty text here would read as «everything deleted». Nor is its
            // version taken: with the newer change tag an upload or a delete from here would pass CloudKit's check and
            // overwrite or remove a text this device never merged. The record is fetched again on its own.
            missing.insert(r.id)
            return
        }
        metas[r.id] = r.meta; tags[r.id] = r.tag
        let position = Sync.sane(r.position), created = Sync.sane(r.created), modified = Sync.sane(r.modified)
        if let n = library.note(id: r.id) {
            let fieldsDirty = dirtyFields.contains(r.id)
            if !fieldsDirty {
                library.updateRemote(n, title: r.title, renamed: r.renamed, created: created, modified: nil, position: position,
                                     pinned: r.pinned)
            }
            let local = n.textSnapshot
            if local.isEqual(to: remote as String) {
                // The same text (this device's own upload coming back, or the same edit made on both).
                clearText(r.id)
            } else if dirtyText.contains(r.id) {
                guard let merged = await merge(n, base: bases[r.id], local: local, remote: remote) else { return }
                library.applyRemote(n, text: merged, modified: nil)
                if merged.isEqual(to: remote as String) { clearText(r.id) }
                else { bases[r.id] = remote; library.store?.baseChanged(r.id) }
            } else {
                library.applyRemote(n, text: remote, modified: nil)
            }
            if !fieldsDirty && !dirtyText.contains(r.id) {
                library.updateRemote(n, title: nil, renamed: nil, created: nil, modified: modified, position: nil)
            }
        } else if deletes.contains(r.id) {
            // Deleted here and not yet sent. If another device changed it since this one last saw it, the change
            // wins over the delete: the note comes back with that text.
            guard knownTag != nil, knownTag != r.tag else { return }
            deletes.remove(r.id)
            library.insertRemote(note(from: r, text: remote))
        } else {
            library.insertRemote(note(from: r, text: remote))
        }
    }

    /// The three-way merge, off the main thread for anything but small texts (10 M characters: ~40 ms, a big rewrite
    /// on both sides: ~0.7 s), so typing never waits for it. Typed into meanwhile: merged again from the new text, so
    /// the result applied always contains every key. nil: the note went meanwhile.
    private func merge(_ n: Note, base: NSString?, local start: NSString, remote: NSString) async -> NSString? {
        var local = start
        while true {
            if local.length + remote.length < 200_000 { return Merge.threeWay(base: base, local: local, remote: remote) }
            let before = edits[n.id, default: 0]
            let job = MergeJob(base: base, local: local, remote: remote)
            let merged = await Task.detached(priority: .userInitiated) { MergeResult(text: job.run()) }.value.text
            guard library.contains(n) else { return nil }
            if edits[n.id, default: 0] == before { return merged }
            local = n.textSnapshot
        }
    }

    /// A note gone for good: nothing of it waits to go up.
    private func forgetPending(_ id: UUID) {
        dirtyText.remove(id); dirtyFields.remove(id)
        if bases.removeValue(forKey: id) != nil { library.store?.baseChanged(id) }
    }

    private func clearText(_ id: UUID) {
        dirtyText.remove(id)
        if bases.removeValue(forKey: id) != nil { library.store?.baseChanged(id) }
    }

    /// Deletions from a fetch. One whose id also came as a record in the same fetch is not a deletion (the record was
    /// made again, by an undo on some device): the record stands. Before a note held here goes, its record is asked
    /// for: if it is there after all, it is taken as a change; only a record truly gone takes the note with it.
    private func receiveDeletions(_ ids: [UUID]) async throws {
        let held = ids.filter { library.note(id: $0) != nil }
        let current = held.isEmpty ? [:] : try await db.fetch(held)
        for id in ids {
            if let r = current[id] {
                if r.text != nil { await receive(r) } else { missing.insert(id) }
            } else {
                receiveDeletion(id)
            }
        }
    }

    func receiveDeletion(_ id: UUID) {
        deletes.remove(id)
        metas[id] = nil; tags[id] = nil
        guard let n = library.note(id: id) else { return }
        if dirtyText.contains(id) || dirtyFields.contains(id) {
            // Changed here meanwhile: kept, and goes up again as a new record.
            dirtyText.insert(id); dirtyFields.insert(id)
            if bases.removeValue(forKey: id) != nil { library.store?.baseChanged(id) }
            schedule(after: delay)
        } else {
            library.removeRemote(n)
        }
    }

    private func note(from r: CloudNote, text: NSString) -> Note {
        let now = Date()
        let created = Sync.sane(r.created) ?? now
        return Note(id: r.id, title: r.title.isEmpty ? library.freeName() : r.title, created: created,
                    modified: Sync.sane(r.modified) ?? created,
                    position: Sync.sane(r.position) ?? (library.notes.map(\.position).max() ?? 0) + 1,
                    renamed: r.renamed, pinned: r.pinned, storage: NSTextStorage(string: text as String))
    }

    /// Numbers from the server are checked before use: a record written by any build, or broken, must not reach the
    /// list or notes.json (a non-finite number there stops the process at every write, on every device). A position
    /// must be finite and within ±10¹²; a date between 2001 and a year from now. nil: keep what is here.
    nonisolated static func sane(_ p: Double) -> Double? { p.isFinite && abs(p) <= 1e12 ? p : nil }
    nonisolated static func sane(_ d: Date) -> Date? {
        let t = d.timeIntervalSinceReferenceDate
        return t.isFinite && t >= 0 && d < Date().addingTimeInterval(366 * 86400) ? d : nil
    }

    // MARK: up

    private func upload() async throws {
        var batchLimit = 200
        while true {
            // A note whose newer server text has not come down yet waits: sending now could overwrite it unmerged.
            let ids = Array(dirtyText.union(dirtyFields)).filter { library.note(id: $0) != nil && !missing.contains($0) }
            let dels = Array(deletes)
            if ids.isEmpty && dels.isEmpty { return }
            // Batches by count and by the bytes of the texts inside the records.
            var batch: [CloudNote] = [], sent: [UUID: (edits: Int, text: NSString?)] = [:], bytes = 0
            for id in ids {
                guard let n = library.note(id: id) else { continue }
                // The text goes when it changed or the record is new; a rename alone sends only the fields.
                let text = dirtyText.contains(id) || metas[id] == nil ? n.textSnapshot : nil
                let size = text.map { $0.length * 3 <= Sync.inlineLimit ? $0.length * 3 : $0.lengthOfBytes(using: String.Encoding.utf8.rawValue) } ?? 0
                let inline = size <= Sync.inlineLimit ? size : 0
                if !batch.isEmpty && (batch.count >= batchLimit || bytes + inline > 1_500_000) { break }
                bytes += inline
                batch.append(CloudNote(id: id, title: n.title, created: n.created, modified: n.modified, position: n.position,
                                       renamed: n.renamed, pinned: n.pinned, text: text, meta: metas[id], tag: tags[id]))
                sent[id] = (edits[id, default: 0], text)
            }
            var delBatch = Array(dels.prefix(max(0, batchLimit - batch.count)))
            if !delBatch.isEmpty {
                // CloudKit deletes whatever version the server has. A record changed on another device since this one
                // last saw it is not deleted: the change wins and the note comes back here with it (receive). One
                // gone already needs no delete.
                let current = try await db.fetch(delBatch)
                var keep: [UUID] = []
                for id in delBatch {
                    guard deletes.contains(id) else { continue }
                    guard let r = current[id] else { deletes.remove(id); metas[id] = nil; tags[id] = nil; continue }
                    if r.tag != tags[id] {
                        // Changed elsewhere: comes back; not yet, and not deleted either, while its text is missing.
                        if r.text != nil { await receive(r) }
                    } else {
                        keep.append(id)
                    }
                }
                delBatch = keep
            }
            let result: (saved: [UUID: SaveOutcome], deleted: [UUID: CloudError?])
            do {
                result = try await db.modify(save: batch, delete: delBatch)
            } catch CloudError.limitExceeded where batch.count + delBatch.count > 1 {
                batchLimit = max(1, (batch.count + delBatch.count) / 2)
                continue
            }
            var firstError: CloudError?
            var progress = false
            for (id, outcome) in result.saved {
                switch outcome {
                case .saved(let meta, let tag):
                    progress = true
                    metas[id] = meta; tags[id] = tag
                    guard let s = sent[id] else { continue }
                    if edits[id, default: 0] == s.edits {
                        dirtyText.remove(id); dirtyFields.remove(id)
                        if bases.removeValue(forKey: id) != nil { library.store?.baseChanged(id) }
                    } else if let t = s.text {
                        // Edited while it travelled: what went is now the base, the rest goes next.
                        bases[id] = t; library.store?.baseChanged(id)
                    }
                case .conflict(let server):
                    progress = true
                    await receive(server)
                    dirtyFields.insert(id)
                    if !dirtyText.contains(id), let n = library.note(id: id), let t = server.text, !n.textSnapshot.isEqual(to: t as String) { dirtyText.insert(id) }
                case .gone:
                    progress = true
                    metas[id] = nil; tags[id] = nil
                    if bases.removeValue(forKey: id) != nil { library.store?.baseChanged(id) }
                case .failed(let e):
                    if e == .zoneNotFound { throw e }
                    firstError = firstError ?? e
                }
            }
            for (id, error) in result.deleted {
                if let error {
                    if error == .zoneNotFound { throw error }
                    firstError = firstError ?? error
                } else {
                    progress = true
                    deletes.remove(id)
                    forgetPending(id)
                }
            }
            library.store?.syncChanged()
            if let firstError { throw firstError }
            if !progress { return }
        }
    }

    // MARK: kept in sync.json

    private struct State: Codable {
        var token: Data?
        var metas: [String: Data]
        var tags: [String: String]
        var dirtyText: [String]
        var dirtyFields: [String]
        var deletes: [String]
        var zoneReady: Bool
        var subscribed: Bool
        var userID: String?
    }

    func syncStateData() -> Data {
        let s = State(token: token, metas: Dictionary(uniqueKeysWithValues: metas.map { ($0.key.uuidString, $0.value) }),
                      tags: Dictionary(uniqueKeysWithValues: tags.map { ($0.key.uuidString, $0.value) }),
                      dirtyText: dirtyText.map(\.uuidString), dirtyFields: dirtyFields.map(\.uuidString),
                      deletes: deletes.map(\.uuidString), zoneReady: zoneReady, subscribed: subscribed, userID: userID)
        return (try? JSONEncoder().encode(s)) ?? Data()
    }

    private func restore(_ data: Data) {
        // Unreadable state costs a full fetch and a full upload, never a note.
        guard let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        func ids(_ a: [String]) -> Set<UUID> { Set(a.compactMap(UUID.init(uuidString:))) }
        token = s.token
        metas = Dictionary(uniqueKeysWithValues: s.metas.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        tags = Dictionary(uniqueKeysWithValues: s.tags.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        dirtyText = ids(s.dirtyText); dirtyFields = ids(s.dirtyFields); deletes = ids(s.deletes)
        zoneReady = s.zoneReady; subscribed = s.subscribed; userID = s.userID
    }

    func base(for id: UUID) -> NSString? { bases[id] }

    // MARK: whether this build may use iCloud

    /// CloudKit needs its entitlement, which only a build signed by the team with its provisioning profile carries;
    /// without it CKContainer stops the process. A build from source by anyone else, or the test binary, has no sync.
    static var available: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else { return false }
        return (v as? [String])?.contains("CloudKit") ?? false
        #else
        return true
        #endif
    }
}

/// The merged text coming back: made on the merge's thread, read only on the main thread after.
private struct MergeResult: @unchecked Sendable { let text: NSString }

/// Immutable texts handed to the merge's thread.
private struct MergeJob: @unchecked Sendable {
    let base: NSString?, local: NSString, remote: NSString
    func run() -> NSString { Merge.threeWay(base: base, local: local, remote: remote) }
}

// MARK: CloudKit

final class CloudKitDatabase: CloudDatabase, @unchecked Sendable {
    static let containerID = "iCloud.com.geragaraza.merum"
    static let subscriptionID = "notes"
    static let recordType = "Note"
    let container = CKContainer(identifier: CloudKitDatabase.containerID)
    var database: CKDatabase { container.privateCloudDatabase }
    let zoneID = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)

    func account() async -> CloudAccount {
        guard let status = try? await container.accountStatus() else { return .unavailable }
        switch status {
        case .available:
            guard let id = try? await container.userRecordID() else { return .unavailable }
            return .available(userID: id.recordName)
        case .noAccount: return .none
        default: return .unavailable
        }
    }

    func ensureZone() async throws {
        do { _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }
        catch { throw Self.map(error) }
    }

    func ensureSubscription() async throws {
        let sub = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent: wakes the app to fetch, shows nothing
        sub.notificationInfo = info
        do { _ = try await database.modifySubscriptions(saving: [sub], deleting: []) }
        catch { throw Self.map(error) }
    }

    func fetchChanges(since token: Data?) async throws -> ZoneChanges {
        let t = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            let r = try await database.recordZoneChanges(inZoneWith: zoneID, since: t)
            var out = ZoneChanges()
            for (_, result) in r.modificationResultsByID {
                if case .success(let m) = result, let n = Self.note(m.record) { out.changed.append(n) }
            }
            out.deleted = r.deletions.compactMap { UUID(uuidString: $0.recordID.recordName) }
            out.token = try? NSKeyedArchiver.archivedData(withRootObject: r.changeToken, requiringSecureCoding: true)   // nosemgrep (CloudKit's server change token, not a secret)
            out.more = r.moreComing
            return out
        } catch {
            throw Self.map(error)
        }
    }

    func fetch(_ ids: [UUID]) async throws -> [UUID: CloudNote] {
        do {
            let r = try await database.records(for: ids.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) })
            var out: [UUID: CloudNote] = [:]
            for (_, result) in r { if case .success(let rec) = result, let n = Self.note(rec) { out[n.id] = n } }
            return out
        } catch {
            throw Self.map(error)
        }
    }

    func modify(save: [CloudNote], delete: [UUID]) async throws -> (saved: [UUID: SaveOutcome], deleted: [UUID: CloudError?]) {
        var files: [URL] = []
        defer { for f in files { try? FileManager.default.removeItem(at: f) } }
        var records: [CKRecord] = []
        for n in save {
            let (rec, file) = record(n)
            records.append(rec)
            if let file { files.append(file) }
        }
        do {
            let r = try await database.modifyRecords(saving: records, deleting: delete.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) },
                                                     savePolicy: .ifServerRecordUnchanged, atomically: false)
            var saved: [UUID: SaveOutcome] = [:], deleted: [UUID: CloudError?] = [:]
            for (rid, result) in r.saveResults {
                guard let id = UUID(uuidString: rid.recordName) else { continue }
                switch result {
                case .success(let rec): saved[id] = .saved(meta: Self.meta(rec), tag: rec.recordChangeTag)
                case .failure(let e):
                    let ck = e as? CKError
                    if ck?.code == .serverRecordChanged, let server = ck?.serverRecord, let n = Self.note(server) { saved[id] = .conflict(server: n) }
                    else if ck?.code == .unknownItem { saved[id] = .gone }
                    else { saved[id] = .failed(Self.map(e)) }
                }
            }
            for (rid, result) in r.deleteResults {
                guard let id = UUID(uuidString: rid.recordName) else { continue }
                switch result {
                case .success: deleted[id] = .some(nil)
                case .failure(let e): deleted[id] = (e as? CKError)?.code == .unknownItem ? .some(nil) : Self.map(e)
                }
            }
            return (saved, deleted)
        } catch {
            throw Self.map(error)
        }
    }

    private func record(_ n: CloudNote) -> (CKRecord, URL?) {
        let rec: CKRecord
        if let meta = n.meta, let coder = try? NSKeyedUnarchiver(forReadingFrom: meta), let r = CKRecord(coder: coder) {
            coder.finishDecoding()
            rec = r
        } else {
            rec = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: n.id.uuidString, zoneID: zoneID))
        }
        rec["title"] = n.title as NSString
        rec["created"] = n.created as NSDate
        rec["modified"] = n.modified as NSDate
        rec["position"] = n.position as NSNumber
        rec["renamed"] = (n.renamed ? 1 : 0) as NSNumber
        rec["pinned"] = (n.pinned ? 1 : 0) as NSNumber
        var file: URL?
        guard let text = n.text else { return (rec, nil) }
        let small = text.length * 3 <= Sync.inlineLimit || text.lengthOfBytes(using: String.Encoding.utf8.rawValue) <= Sync.inlineLimit
        if small {
            rec["text"] = text
            rec["textAsset"] = nil
        } else {
            // The asset's file lives only until the upload ends (removed in modify).
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("merum-\(n.id.uuidString)-\(UUID().uuidString).txt")
            if (try? Store.utf8(text).write(to: url)) != nil {
                rec["text"] = "" as NSString
                rec["textAsset"] = CKAsset(fileURL: url)
                file = url
            } else {
                rec["text"] = text
            }
        }
        return (rec, file)
    }

    static func note(_ r: CKRecord) -> CloudNote? {
        guard let id = UUID(uuidString: r.recordID.recordName) else { return nil }
        var text: NSString? = (r["text"] as? String).map { $0 as NSString } ?? ""
        if let asset = r["textAsset"] as? CKAsset {
            text = asset.fileURL.flatMap { try? Data(contentsOf: $0) }.map(Store.decode)
        }
        return CloudNote(id: id, title: r["title"] as? String ?? "", created: r["created"] as? Date ?? r.creationDate ?? Date(),
                         modified: r["modified"] as? Date ?? r.modificationDate ?? Date(),
                         position: (r["position"] as? NSNumber)?.doubleValue ?? 0,
                         renamed: ((r["renamed"] as? NSNumber)?.intValue ?? 0) != 0,
                         pinned: ((r["pinned"] as? NSNumber)?.intValue ?? 0) != 0, text: text, meta: meta(r), tag: r.recordChangeTag)
    }

    static func meta(_ r: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        r.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func map(_ error: Error) -> CloudError {
        guard let e = error as? CKError else { return .other("\(error)") }
        switch e.code {
        case .changeTokenExpired: return .tokenExpired
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        case .notAuthenticated: return .notAuthenticated
        case .quotaExceeded: return .quotaExceeded
        case .limitExceeded: return .limitExceeded
        case .requestRateLimited, .zoneBusy, .serviceUnavailable, .networkFailure, .networkUnavailable, .serverResponseLost:
            return .retryAfter(e.retryAfterSeconds ?? 10)
        case .partialFailure:
            // A whole-zone error inside: the zone is gone.
            if let parts = e.partialErrorsByItemID?.values, parts.contains(where: { ($0 as? CKError)?.code == .zoneNotFound || ($0 as? CKError)?.code == .userDeletedZone }) { return .zoneNotFound }
            return .retryAfter(e.retryAfterSeconds ?? 10)
        default: return .other("\(e.code.rawValue)")
        }
    }
}

// MARK: settings

/// Sort and direction, the same on every device of one iCloud account through the key-value store: one key holding
/// both and the time of the edit; the later edit wins. Without the entitlement nothing is sent. Text size is not here:
/// it is each device's own (Library.textSize); a «textSize» an older build wrote into the record is ignored.
@MainActor final class SettingsSync {
    let library: Library
    private var store: NSUbiquitousKeyValueStore?
    static let key = "settings"   // nosemgrep (the name of a settings key, not a secret)

    init(library: Library) { self.library = library }

    func start() {
        guard store == nil, SettingsSync.available else { return }
        library.settingsSync = self
        let s = NSUbiquitousKeyValueStore.default
        store = s
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: s, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.take() }
        }
        s.synchronize()
        take()
    }

    func localChanged() {
        library.settingsModified = Date().timeIntervalSince1970
        send()
    }

    private func send() {
        guard let store else { return }
        store.set(record(), forKey: SettingsSync.key)
        store.synchronize()
    }

    /// What goes into the key-value store.
    func record() -> [String: Any] {
        ["t": library.settingsModified, "sort": library.sort.rawValue, "ascending": library.ascending]
    }

    private func take() {
        guard let store else { return }
        if apply(store.dictionary(forKey: SettingsSync.key)) { send() }
    }

    /// Takes a record from the store if it is newer than this device's settings; true when this device's are newer
    /// (or the store has none) and should be sent.
    func apply(_ d: [String: Any]?) -> Bool {
        guard let d, let t = d["t"] as? Double, t.isFinite, t < Date().timeIntervalSince1970 + 86400 else {
            return library.settingsModified > 0   // the first device to have them
        }
        if library.settingsModified > t { return true }
        if library.settingsModified == t { return false }
        library.updateSettingsRemote(sort: (d["sort"] as? String).flatMap(Library.Sort.init(rawValue:)), ascending: d["ascending"] as? Bool)
        library.settingsModified = t
        return false
    }

    static var available: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil) != nil
        #else
        return true
        #endif
    }
}
