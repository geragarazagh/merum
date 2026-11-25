// Debug builds only, and only when launched with -merumCloudCheck: proves on a device that iCloud works end to end.
// Account, key-value store, then a note made, uploaded, read back from the private database, deleted and seen gone.
// Writes its findings to tmp/cloud-check.txt in the app's container (read with devicectl's copy from); nothing else.
#if DEBUG && MERUM_ICLOUD
import CloudKit
import UIKit

@MainActor enum CloudCheck {
    static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-merumCloudCheck") else { return }
        Task { await run() }
    }

    private static var lines: [String] = []
    private static func say(_ s: String) {
        lines.append(s)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cloud-check.txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func run() async {
        let app = Merum.shared
        let container = CKContainer(identifier: CloudKitDatabase.containerID)
        let db = container.privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)
        say("start \(Date())")
        do { say("account \(try await container.accountStatus().rawValue) (1 = available)") } catch { say("account error \(error)") }
        let kv = NSUbiquitousKeyValueStore.default
        say("kvstore synchronize \(kv.synchronize()) keys \(kv.dictionaryRepresentation.keys.sorted())")
        guard let sync = app.sync else { say("no Sync"); return }

        var ended: [Date: String] = [:]
        let previous = sync.onRunEnded
        sync.onRunEnded = { e in previous?(e); ended[Date()] = e.map { "\($0)" } ?? "ok" }
        func waitRun(after t: Date) async -> String {
            for _ in 0..<120 {
                if let r = ended.filter({ $0.key > t }).sorted(by: { $0.key < $1.key }).last?.value { return r }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return "timeout"
        }

        let n = app.library.newNote()
        n.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Merum iCloud check \(Date())")
        let made = Date()
        say("note \(n.id.uuidString) made; run after it: \(await waitRun(after: made))")

        do {
            let zones = try await db.allRecordZones().map(\.zoneID.zoneName)
            say("zones \(zones)")
            let subs = try await db.allSubscriptions().map(\.subscriptionID)
            say("subscriptions \(subs)")
            let changes = try await db.recordZoneChanges(inZoneWith: zone, since: nil)
            let names = changes.modificationResultsByID.keys.map(\.recordName)
            say("records in zone \(names.count); the new note there: \(names.contains(n.id.uuidString))")
            if let r = try? changes.modificationResultsByID[CKRecord.ID(recordName: n.id.uuidString, zoneID: zone)]?.get().record {
                say("its fields: title=\(r["title"] as? String ?? "-") text=\((r["text"] as? String ?? "").prefix(40))")
            }
        } catch { say("read error \(error)") }

        let deleted = Date()
        app.library.delete([n])
        say("deleted; run after it: \(await waitRun(after: deleted))")
        do {
            let changes = try await db.recordZoneChanges(inZoneWith: zone, since: nil)
            say("after delete, the note still there: \(changes.modificationResultsByID.keys.contains { $0.recordName == n.id.uuidString })")
        } catch { say("read error \(error)") }
        say("done")
    }
}
#endif
