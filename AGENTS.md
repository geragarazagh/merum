# AGENTS.md — Merum

Plain-text notes on Mac and iPhone, kept in step through iCloud. Swift, AppKit on the Mac, SwiftUI + UIKit on the
iPhone, one shared core. Bundle id `com.geragaraza.merum` on both platforms (one App ID), CloudKit container
`iCloud.com.geragaraza.merum`, key-value store `$(TeamIdentifierPrefix)com.geragaraza.merum`.

Speed comes first: a note of one character and a note of ten million characters must feel the same to type, scroll,
select, paste, undo and switch to. Every choice below that looks unusual is there for that.

## Layout

```
shared/   the core, compiled into both apps (no AppKit-only or UIKit-only code except behind #if os(macOS) / os(iOS))
mac/      the Mac app (AppKit), built by ./build with plain swiftc
ios/      the iPhone app (XcodeGen project.yml, `ios/make` generates Merum.xcodeproj; the project file is not in git)
tests/    core tests runnable on the Mac without Xcode UI (`./test`)
skills/merum/SKILL.md   copied by ./build into Merum.app/Contents/Resources/SKILL.md
```

## Minimums

- Mac: Apple silicon, macOS 13 or later (`-target arm64-apple-macos13`). No API newer than 13 without an
  `if #available` path that behaves the same for the person. That is why sync uses plain CloudKit operations, not
  CKSyncEngine (macOS 14).
- iPhone: iOS 26 or later, iPhone only (`TARGETED_DEVICE_FAMILY 1`, set per target too), laid out from size classes
  and safe areas only (iPhone Duo).

## The core (shared/)

One `Library` object per process owns everything; the UI only reads it and calls it.

- `Note` (class): `id: UUID`, `title: String`, `created: Date`, `modified: Date` (text or title changed),
  `position: Double` (manual order), `storage: NSTextStorage` (the live text; plain, the UI sets its attributes),
  `renamed: Bool` (the person gave it a name). The text lives only in `storage`; nothing keeps a second copy.
- Default names: English ordinal words + « Note», the lowest one no current note carries: «First Note»,
  «Second Note» … «Twenty-First Note» … «Ninety-Eighth Note», and on past 98 without limit («One Hundredth Note»,
  «One Hundred First Note»). `Ordinal.words(n)`.
- `Library` API (main thread):
  - `notes: [Note]` in the current sort; `sort: Sort` (`.manual`, `.edited`, `.created`, `.title`) and
    `ascending: Bool`; changes posted as `Library.didChange` (with what changed: list, one note's title, one note's
    text from outside).
  - `newNote() -> Note` (default name; manual order puts it last), `delete(_ notes: [Note])`, `rename(_:to:)`,
    `move(_ notes:, toIndex:)` (manual order), `note(id:)`.
  - `lastOpen: UUID?` per device (not synced): the window always opens on it.
  - `leave(_ note:)`: called when the UI switches away from a note; a note left empty that was never renamed is
    removed silently (as Apple Notes drops an empty note), the last one too (then there are no notes). Not an undo step.
  - When there are no notes, the editor stays editable and the first edit creates a note (`ensureNote()`): input
    never goes nowhere.
- `History` (one per process, wraps one `UndoManager`): one time-ordered undo history for text edits in every note
  and for whole notes (delete, create, rename, move). The text views do NOT keep their own undo
  (`NSTextView.allowsUndo = false`; on iPhone the text view's own registrations are swallowed, see ios/). The UI
  reports each edit before it happens: `history.willReplace(in: note, range:, with:)`; the core coalesces typing the
  way NSTextView does (consecutive insertions at the caret, or consecutive deletions, form one step until the caret
  moves, the note changes or a non-typing edit comes), and groups an input method's marked-text run into one step.
  Undo of a text step in a note not on screen calls `history.reveal(note, selection)` so the UI switches to it first.
  Registrations use a per-note target so a change arriving from another device can drop only that note's text steps
  (`removeAllActions(withTarget:)`). Action names in Apple's words: «Typing», «Paste», «Cut», «Delete», «Delete
  Note», «Delete Notes», «New Note», «Rename Note», «Move Note». The history lives while the app runs; quitting
  ends it. There is no Trash and no Recently Deleted.
- `Store`: files in one removable place. Mac `~/Library/Application Support/Merum/`, iPhone the app container's
  Application Support/Merum. `notes.json` (metadata, sort), `Notes/<id>.txt` (UTF-8 text, one file per note),
  `sync.json` (CloudKit state). Writes are atomic, debounced, off the main thread from a snapshot of the text, and
  flushed on hide, background and quit. Nothing else is written anywhere (no caches, no logs).
- `Sync` (CloudKit, private database, zone `Notes`, record type `Note`): fields `title`, `created`, `modified`,
  `position`, `renamed`, and the text as `text` (String) while under a size safe for a record, else as `textAsset`
  (CKAsset file) with `text` empty. Uploads debounce after edits; changes come by a silent push on the zone
  (`CKRecordZoneSubscription`, content-available) and by a fetch whenever the window is shown or the app comes
  forward. A change from another device is applied to the note's `storage` as the smallest replacement (common
  prefix and suffix kept), so the caret and scroll of an open note stay where they were. Conflicts never lose
  text: a three-way merge against the last synced text; overlapping changes keep both versions. No iCloud account,
  no network: everything works locally and catches up later. Sort settings and text size sync through the
  key-value store.
- `Paste`: everything put into a note becomes text. Files (copied, dragged) become their full paths, one per line.
  A picture with no file behind it (a screenshot straight to the clipboard) becomes its text, recognised by Apple's
  Vision on the device in every language Vision offers, detected automatically. Rich text becomes its plain string.
  Never «nothing».

### The core's API as built (main thread unless said; kept true by whoever changes shared/)

Startup: `let library = Library(store: Store())` (loads everything: ~40 ms for a 10 M-character note); then, only when
`Sync.available` (the build carries the CloudKit entitlement; without it `CKContainer` would stop the process),
`Sync(library:, database: CloudKitDatabase()).start()`; `SettingsSync(library:).start()` (checks its own entitlement).
Keep both objects alive (the library holds them weakly).

- `Note`: as above, plus `pinned: Bool` (the owner's wish 2026-11-25: pinned notes stand apart on top, Apple Notes'
  way), `textSnapshot: NSString` (immutable copy, ~1 ms per 10 M characters), `length`.
- `Ordinal.words(n) -> String` («Twenty-First»), `Ordinal.noteName(n)` («Twenty-First Note»), `Ordinal.cardinal(n)`.
- `Library`: `notes` (two groups, pinned first, each in the current sort; in `.manual` each keeps its own order; Notes'
  English strings have «Pinned» for the pinned group's heading; the heading of the rest was not found there), `sort`, `ascending` (ignored by `.manual`), `textSize` (percent; snaps to
  `Library.textSizes` = 50 75 100 125 150 175 200 250 300), `lastOpen` (the UI sets it whenever it shows a note; after
  a delete it moves to the note that took the open one's place, else the one above), `history`, `note(id:)`,
  `contains(_:)`, `newNote()`, `ensureNote()`, `delete(_:)`, `leave(_:)` (a note left empty and never renamed vanishes, the last one too: zero notes is a normal state, the UI
  shows the empty state and the first key makes a note; only a note the person made or emptied on this device while
  the app runs: one that came empty from iCloud or from disk and was not touched here stays, since another device may
  have it open or its text may not have arrived), `rename(_:to:)` (an empty name gives the
  default name back), `pin(_ notes:, _ on: Bool)` (one undo step «Pin Note», «Pin Notes», «Unpin Note», «Unpin
  Notes», Notes' own strings; the date edited stays), `move(_:toIndex:)` (only while `sort == .manual`; `toIndex` as a
  table's drop row in `notes`; only the first moved note's group moves, and an index outside it stops at the group's
  edge), `flush()`
  (call on hide, background, quit). Default sort `.manual`, ascending: ⌘1…⌘9 keep pointing at the same notes.
  `Library.didChange` userInfo[`Library.changeKey`] is a `Library.Change`: `.list`, `.title(Note)`,
  `.text(Note, range:, delta:)` (another device's change, already applied), `.settings`.
- The core writes into `storage` with `replaceCharacters(in:with: String)` (undo, redo, other devices): the inserted
  text inherits the attributes around it, and the UI keeps attributes uniform (e.g. in its storage delegate's
  willProcessEditing, or by typingAttributes when the storage was empty).
- `History`: `undoManager` (hand it to the window / text view), `reveal: ((Note, NSRange?) -> Void)?` (after an undo
  or redo changed a note's text, with the range to select; also with nil after one note came back: show it, switching
  notes if needed), `willReplace(in:range:with:as:)` with `History.Kind` `.typing` (keys, Delete, Forward Delete,
  marked text, dictation), `.paste`, `.cut`, `.delete` (Edit > Delete), `.named("Drag")` etc., `breakTyping()` (call
  when the person moves the caret or selection: a click, an arrow key; never during an edit or while marked text is
  being composed). Typing coalesces as NSTextView's does, Delete after typing included. The Edit menu always names
  what ⌘Z will do: a note's own steps (created, renamed) leave the stack when the note goes without an undo step
  (`leave`, deleted on another device), and a group holding a whole-note step is named after it (a new note and its
  first key in one event: «Undo New Note», still true once another device's change drops the typing). As a last
  guard a group that finds nothing to do is passed over. Undoing a text step of a note `leave` dropped brings the
  note back.
- `Store(dir:)`: `Store.defaultDirectory` = Application Support/Merum. Files: `notes.json`, `Notes/<id>.txt`,
  `sync.json`, and `Base/<id>.txt` (deviation: the text as last synced, only for notes whose edits have not reached
  iCloud yet, so a three-way merge after a quit still has its base; deleted once the upload lands). Writes one second
  after the first change of a burst.
- `Sync`: `setForeground(true/false)` (call true when the Mac window is shown / the iPhone app becomes active, false
  when hidden / in the background: in front it fetches at once and every 15 s, as silent pushes are throttled and
  once took over 90 s), `fetchNow()`, `handlePush(userInfo) -> Bool` (the app registers for remote
  notifications and passes them on; the subscription is silent, content-available), `Sync.available`. Deviations: a
  note deleted on one device and edited on the other comes back with the edits (never lose text); a record whose text
  is too big to be inline (`Sync.inlineLimit`, 500 000 UTF-8 bytes) carries it in `textAsset`; uploads 1.5 s after the
  last edit (5 s for big texts). The three-way merge runs off the main thread for texts over 200 000 units (10 M
  characters: ~40 ms, both sides rewritten: ~0.7 s) and is applied only if the note was not typed into meanwhile,
  else merged again from the new text: no conflict stalls typing. Another iCloud account signed in (decided): sync
  starts over against it, local notes stay and go up to it; nothing is ever lost.
- Record field `pinned` Int(64) 0/1 beside the others; a record without it (made before pinning) reads as unpinned.
  notes.json keeps `pinned` per note.
- What a client may delete in iCloud (2026-11-25, after records vanished in tests): only a record of a note it holds
  (fetched or uploaded) and the person deleted (Delete, ⌘A Delete, undo of New Note) or `leave` dropped (made here).
  Before a delete goes, the record is fetched: one changed on another device since this one last saw it is not
  deleted, and the note comes back with that change. A note deleted elsewhere while this device has unsynced edits
  stays and goes up again. A deletion coming from iCloud is checked too: a note held here goes only if its record is
  really gone (asked for first), and an id that comes both as a record and as a deletion in one fetch is kept. ⌘A ⌘⌫
  then ⌘Z before the deletes went sends nothing (unsynced edits from before still go). Zone re-creation, an expired token, another account: no deletes. `Sync.start()` does
  nothing unless the library's folder is `Store.defaultDirectory`: a copy run on a scratch folder (`--data`) must set
  `sync.anyFolder = true` before `start()` to sync on purpose, else it would fetch the person's notes and send its
  test deletions to every device.
- `SettingsSync`: key-value store key `settings` = {t, sort, ascending, textSize}; the later edit wins.
- `Paste`: `Paste.content(of: NSPasteboard / UIPasteboard) -> Paste.Content?` (`.text(String)` at once, or
  `.image(CGImage)` to read), `Paste.recognize(CGImage) async -> String` ("" when the picture has no text: beep),
  `Paste.text(from:) async -> String?` (both in one; nil: nothing that reads as text). Recognition is the OCR app's
  pipeline (`Recognition`, shared/recognition.swift).
- A paste that waits (a picture read by Vision: ~0.4 s, over a minute the first time after a restart while Vision
  prepares its model): `await library.paste(content, into: note, replacing: selection) -> NSRange?` does it all; or
  `beginPaste(in:replacing:) -> PendingPaste`, then `finishPaste(_:with:)` / `cancelPaste(_:)`. Meanwhile the person
  types and switches notes freely: the paste's place follows every edit (typing at that very place stays after it,
  as typed later), the note is not dropped as empty by `leave`, the text goes in as one undo step «Paste» where the
  paste was made (over the selection it was made on, unless that text was edited meanwhile: then nothing is removed);
  a note deleted meanwhile still gets it, so undoing the delete brings both back; a picture with no text puts nothing
  in (beep) and the spared empty note goes as it would have. The UI shows nothing special while it waits and does not
  move the caret when the text lands. `library.pastes` lists those waiting.
- `Facts` (shared/facts.swift, the one copy; mac/ and ios/ keep none): `Facts(string)` counts at once;
  `await Facts.of(note.textSnapshot) -> Facts?` counts off the main thread and returns nil when the calling task was
  cancelled (cancel the previous count on each edit; 10 M characters: ~0.5 s off the main thread, given up within
  ~20 ms). `line` «24 characters · 4 words · ≈ 7 tokens» (Copia's line, lowercase), `lines` capitalised
  («1,234 Characters», …: the iPhone's bar is `lines.joined(separator: " · ")`).
- `Diff.minimalReplacement(from:to:)`, `Merge.threeWay(base:local:remote:)`: used by Sync, public for tests.

### iCloud: signing and set-up (done 2026-11-25)

- App ID `com.geragaraza.merum` (one for Mac and iPhone) has iCloud (CloudKit, container `iCloud.com.geragaraza.merum`,
  key-value storage) and Push Notifications, registered by Xcode's automatic signing from a throwaway XcodeGen wrapper
  (release.md, «iCloud in a Developer ID app»). The container exists in the team's account.
- `Merum.provisionprofile` beside the source (out of git, .gitignore): «Mac Team Direct Provisioning Profile:
  com.geragaraza.merum», Developer ID, all Macs, expires 2044-11-20. A Developer ID build copies it to
  `Contents/embedded.provisionprofile` before signing and signs the app (hardened runtime, no sandbox) with exactly
  these entitlements, what Xcode's developer-id export signed the wrapper with:
  `com.apple.application-identifier` = `4PWXU4KC48.com.geragaraza.merum`;
  `com.apple.developer.team-identifier` = `4PWXU4KC48`;
  `com.apple.developer.icloud-container-identifiers` = [`iCloud.com.geragaraza.merum`];
  `com.apple.developer.icloud-services` = [`CloudKit`];
  `com.apple.developer.icloud-container-environment` = `Production`;
  `com.apple.developer.aps-environment` = `production`;
  `com.apple.developer.ubiquity-kvstore-identifier` = `4PWXU4KC48.com.geragaraza.merum`.
  Only when SIGN_ID is this team's: a build from source by anyone else has no iCloud (`Sync.available` and
  `SettingsSync.available` read the entitlements and stay off; without them CKContainer would stop the process).
- The app registers for remote notifications at launch (Mac `NSApp.registerForRemoteNotifications()`, iPhone
  `UIApplication.shared.registerForRemoteNotifications()` plus `UIBackgroundModes` `remote-notification`) and hands
  every notification to `sync.handlePush(_:)`. iPhone entitlements: the same container, services, key-value store
  and `aps-environment` (Xcode writes development for device builds, production on App Store export).
  In ios/project.yml: the entitlements on the Merum target, `UIBackgroundModes` `remote-notification`, and the
  compilation condition `MERUM_ICLOUD` (target level, so Debug keeps DEBUG beside it) that starts Sync and
  SettingsSync. A Debug build launched with `-merumCloudCheck` (ios/app/CloudCheck.swift) makes a note, waits for the
  upload, reads it back from the private database, deletes it and writes what it saw to tmp/cloud-check.txt in the
  app's container (`devicectl device copy from`). Run on the iPhone 15 Pro 2026-11-25 10:48 UTC: account available,
  zones `_defaultZone` and `Notes`, subscription `notes`, the record with its title and text, gone after the delete.
- CloudKit schema: Developer ID and App Store builds use the Production environment, where record types are never
  created on the fly, so the schema (zone `Notes` is made by the app; record type `Note`: `title` String, `created`
  Date/Time, `modified` Date/Time, `position` Double, `renamed` Int(64), `pinned` Int(64), `text` String, `textAsset`
  Asset; `pinned` added 2026-11-25) must be deployed to Production once, by the owner, in CloudKit Console: icloud.developer.apple.com > CloudKit Database >
  container iCloud.com.geragaraza.merum > Development > «Deploy Schema Changes…» > Deploy. The Development schema is
  already there (made by a development-signed run that saved one record of every field and deleted it again).
  Until that click a signed build's uploads are refused by CloudKit (no type Note in Production) and
  everything stays local. Any later new field needs the same deploy before the build that uses it ships.

## The Mac app (mac/)

- `main.swift` entry (`--login`, `--background`, merum-cli, one copy at a time); `app.swift` show and hide (regular
  app with Dock icon and menus while the window shows, accessory when hidden; `NSApp.hide` hands the focus back; sync
  foreground on show, off on hide). A press that lands during a Space switch is made good: for 1.6 s the window is
  brought onto the Space in use if it was left off it, and the activation is asked again only when a Space switch ends
  after the press, never on a timer (a second request landed after the person's click elsewhere and took the focus);
  measured 2026-11-25 in the macOS 27 machine: 427 checks over desktops, a full-screen app, Mission Control, Stage
  Manager on and off, double presses and a click elsewhere 0.25 s after a show, 0 failures. Keep on Top = the window
  floats the whole time it is shown (switching level on activation blinked it behind other apps' windows, his first
  look), and any other window of the app floats too when it becomes key. `window.swift` the window: first size
  926 x 606 (TextEdit's 98 x 32 characters in 13 pt SF, sidebar 241), minimum 542 x 332 (the toolbar's buttons need
  328 pt beside a 182 pt sidebar, measured; five list rows), sidebar 182-360 pt; a width at which a toolbar button
  goes into the » overflow raises the minimum on the spot. Toolbar: sidebar, New Note, Share, «…», Search.
  `sidebar.swift` the list (two-line rows as Apple Notes, «Pinned» and «Notes» groups that scroll with the rows,
  selection, rename, drag inside a group, delete, copy, search, animated rows; while a row is dragged the rows stay as
  they are and the move is made after the drag session ends: a change under it crashed AppKit, 2026-11-25 14:09:58;
  a right click on empty space offers New Note); `editor.swift` a TextKit 1 view per note (12 kept; a note left is
  taken out of the window, not hidden, so live resize touches only the open one), edits reported to History, paste
  through Paste and `library.paste` for pictures, the counts line (`Facts.of`); `menu.swift`; `hotkey.swift` (default
  ⌥⌘M, `Shortcut.standard`); `settings.swift`; `save.swift`; `cli.swift`; `clipboard.swift`; `updates.swift`;
  `icon.swift` (`icon --document`); `trial.swift` scripted checks in ad hoc builds only, refused on the real notes
  folder or a folder that syncs, with no hot key of their own; `TEST=1 ./build` makes «Merum Test.app»
  (com.geragaraza.merum.test) to run beside an installed Merum.
- Mac-only settings in the app's defaults (hot key, Keep on Top, Save To, spelling, the window's frame, the caret of
  the note open at quit); the notes in the core's Store only. Apple's frameworks add two caches of their own, measured
  2026-11-25 and not ours to stop: `~/Library/Caches/CloudKit/com.geragaraza.merum` (CloudKit, a signed build) and
  `~/Library/Caches/com.geragaraza.merum/com.apple.e5rt.e5bundlecache` (Vision's model, after a picture is read).
- `./build` (ad hoc, Command Line Tools enough; full Xcode for Assets.car and docs/icon*.png), `SIGN_ID="Developer ID
  Application: Herman Harazha (4PWXU4KC48)" ./build` with iCloud. `vendor/` (Sparkle, checked by hash) and Merum.app are
  build products (.gitignore). Trials: `Merum.app/Contents/MacOS/Merum --data DIR --trial SCRIPT` (commands in
  trial.swift's head) writes SCRIPT.out and quits; a private clipboard, nothing of the person's touched. Menu steps in a
  trial are not events and share one undo group; keys are posted events and behave as typed.

## Behaviour that must not change

- Plain text only: no formatting, no links that react, no data detectors, no attachments.
- Font: the system font (San Francisco). Text size steps 50, 75, 100, 125, 150, 175, 200, 250, 300 %, lines rewrapped
  at every step; ⌘+ ⌘− ⌘0.
- The window (Mac) appears and hides on one global hot key the person chooses, over every window including
  full-screen apps; Dock icon and menu bar only while the window is shown; never a menu bar icon.
- Selection and accent colours are the person's own from System Settings.
- Interface text in English only; system terms copied from macOS's and iOS's English strings.
- No network besides iCloud and Sparkle's update check (Mac).

## Measured

Text engine, 2026-11-25, MacBook Pro M3 Pro, macOS 27.2.1. NSTextView in an offscreen 700 x 800 pt window, plain text,
system font 13 pt, wrapping to the width; every number includes layout and drawing of the window (displayIfNeeded +
CATransaction.flush). TK1 = TextKit 1, NSLayoutManager with allowsNonContiguousLayout; TK2 = NSTextLayoutManager.
«W&P» = bench/war-and-peace.txt (3.0 M UTF-16 units), «10M» = bench/ten-million.txt (10.0 M).

| | TK1 W&P | TK2 W&P | TK1 10M | TK2 10M |
|---|---|---|---|---|
| open: text in, first screen drawn | 26 ms | 29 ms | 39 ms | 42 ms |
| keystroke at start, insert (median / max) | 2.9 / 7.7 ms | 1.2 / 5.5 | 2.8 / 7.4 | 1.2 / 5.4 |
| keystroke in the middle | 2.1 / 2.7 | 3.0 / 3.6 | 1.7 / 2.7 | 1.6 / 2.1 |
| keystroke at the end | 0.9 / 1.7 | 0.8 / 1.1 | 0.8 / 1.4 | 0.6 / 0.7 |
| scroll the whole text page by page (frame median / max) | 2.1 / 6.7 ms | 4.9 / 13.5 | 2.1 / 4.6 | 5.3 / 83.7 |
| smooth scroll, 24 pt a frame (median / max) | 0.5 / 0.8 | 0.9 / 2.3 | 0.5 / 0.9 | 2.9 / 12.1 |
| jump by the scroller to 25/50/75/90 % | 7-17 ms | 4-6 | 1-38 | 4-6 |
| select all | 2.0 ms | 7.8 | 3.9 | 31.1 |
| ⌘A ⌘X (whole text) | 29 ms | 12 | 94 | 58 |
| paste the whole text into an empty note | 27 ms | 23 | 53 | 99 |
| typing at the end after that paste (median / max) | 0.9 / 2.2 | 0.9 / 2.4 | 0.7 / 1.4 | 3.3 / 15.4 |
| text size step with rewrap, caret mid-text | 27 ms | 5 | 72 | 16 |
| live resize, rewrap mid-text (frame median / max) | 6.1 / 9.3 | 4.3 / 9.6 | 5.6 / 6.4 | 9.4 / 23.1 |
| find every «Наполеон» (case/diacritic-insensitive NSString search) | 109 ms | 111 | 366 | 675 |
| memory after open | 174 MB | 159 | 225 | 212 |
| memory after scrolling through the whole text | 377 MB | 969 | 653 | 2255 |
| switch between two big notes, a text view per note | 0.4 ms | 1.9 | 0.4 | 8.2 |
| switch, one view, storage swapped under it | 2.2 ms | 6.5 | 2.3 | 16.4 |
| back to the caret mid-text after a storage swap | 27 ms | 5.5 | 70 | 15 |

Chosen: TextKit 1 with non-contiguous layout. It scrolls two to ten times faster (TK2's frames reach 84 ms on 10M),
needs a third of the memory once a big text has been seen (TK2: 2.3 GB for 10M), and selects all, switches notes and
types after a huge paste without a frame lost. TK2 wins only on discrete steps (text size, ⌘X), all under 100 ms on
TK1 too. Notes: one TK1 text view and layout manager per note (six W&P notes: 62 MB as storages alone, the first view
+124 MB for the text system's one-time setup, each further view +5 MB; switching among six: 2.1 ms median), kept for
the most recently opened notes; an older note's layout manager is detached and rebuilt when it is opened again
(measured cost: the «back to the caret» row). The views are created with an explicit NSLayoutManager, so AppKit never
builds TK2 for them.

In the app (TRIALS build, keys posted as real NSEvents, each to the window drawn), 2026-11-25:

| | M3 Pro, macOS 27.2.1 | test machine macOS 27.2 (4 cores) |
|---|---|---|
| typing in W&P at start / middle / end, median | 3.5 / 5.3 / 2.4 ms | 3.6 / 4.8 / 1.8 ms |
| same, slowest key of 120-150 | 5.9 / 11.8 / 4.7 ms | 9.8 / 13 / 13 ms |
| typing in 10M at start / middle / end, median (slowest) | 3.6 (8.0) / 4.1 (7.6) / 2.7 (5.0) ms | 3.8 (8.9) middle |
| longest main-thread stretch while typing | 12.2 ms (W&P, middle) | 14 ms |
| memory: a small note / + W&P / + 10M, typed in | 152 / 193 / 305 MB | |
| a note of 10M made from text (merum-cli new path) | | 73 ms |
| typing in 10M, middle, with the counts line live: median / slowest / longest main-thread stretch | 3.2 / 6.8 / 7.0 ms | |
| counts of 10M (off the main thread) / its copy on the main thread | 2.1 s / 1.4 ms | |
| paste of 10M | | 59-87 ms |
| a picture's text (two lines, Russian and English) | 0.5 s; 77 s the first time after a restart (Vision preparing its model) | no Vision in a test machine |

The first key in a note that mixes languages (W&P's French-Russian first page) waited 0.4 s in the test machine
while the spelling service loaded a second language; the editor now asks the service in the background for each
note's beginning when it is opened (EditorController.warmSpelling): 12 ms a second after opening.

## Measured (iPhone)

Text engine, 2026-11-25, iPhone 15 Pro (iPhone16,1), iOS 27.2.1, a throwaway hosted-XCTest bench (removed from the
phone after). UITextView, plain text, Dynamic Type body (17 pt), keyboard up while typing. Every number is main-thread
work: the operation, then layoutIfNeeded and CATransaction.flush, so the drawing of the next frame is included (the
budget at 120 Hz is 8.3 ms). TK1 = an explicit NSLayoutManager with allowsNonContiguousLayout; TK2 = an explicit
NSTextLayoutManager over NSTextContentStorage. A view per note, built over the note's storage, as the app does.

| | TK1 W&P | TK2 W&P | TK1 10M | TK2 10M |
|---|---|---|---|---|
| read + decode UTF-8 from disk | 11 ms | 7 | 31 | 33 |
| storage made with attributes | 22 ms | 25 | 41 | 45 |
| open: view built over it, shown, first screen drawn | 25 ms | 16 | 142 | 12 |
| keyboard up on that note | 48 ms | 58 | 14 | 44 |
| keystroke at start (median / max) | 3.9 / 15.1 ms | 1.4 / 2.0 | 5.1 / 8.0 | 1.6 / 3.4 |
| keystroke in the middle | 2.5 / 6.1 | 3.8 / 28.6 | 2.9 / 7.0 | 2.7 / 91.7 |
| keystroke at the end | 1.2 / 1.6 | 2.6 / 38.0 | 3.3 / 5.5 | 1.8 / 202.1 |
| backspace (median, any place) | 2.2-4.7 | 2.1-6.3 | 4.3-6.0 | 2.1-5.9 |
| jump to end / start / middle | 0.0 / 0.0 / 0.5 ms | 0.3 / 0.6 / 3.7 | 0.0 / 0.0 / 0.8 | 0.1 / 0.6 / 8.4 |
| whole text top to bottom in 600 frames (median / max, frames over 8.3 ms) | 3.9 / 12.0 (3) | 5.2 / 56.0 (41) | 3.9 / 5.6 (0) | 5.3 / 233.2 (57) |
| finger scroll, 40 pt a frame (median / max, over 8.3 ms) | 0.7 / 1.2 (0) | 5.4 / 17.4 (10) | 0.7 / 1.9 (0) | 5.6 / 14.8 (22) |
| text size step 100 → 125 % / back, whole text re-attributed | 63 / 31 ms | 84 / 60 | 127 / 78 | 202 / 229 |
| select all, keyboard up | 610 ms | 158 | 614 | 467 |
| cut all: plain string to the pasteboard / storage emptied | 104 / 9 ms | 106 / 15 | 362 / 9 | 357 / 34 |
| paste all: pasteboard read / into the storage | 46 / 46 ms | 38 / 100 | 168 / 93 | 134 / 337 |
| the same paste through UITextInput replace(_:withText:) | 5 707 ms | 5 796 | (not run: tens of s) | |
| typing right after that paste (median / max) | 1.1 / 18.6 | 51.3 / 82.5 | 3.6 / 60.3 | 1.7 / 234.1 |
| switch to a small note's view and back (median) | 0.7 / 3.2 ms | 0.6 / 2.9 | 0.6 / 2.8 | 0.6 / 2.3 |
| typing right after the switch back (median / max) | 3.6 / 4.6 | 4.2 / 30.0 | 4.8 / 5.5 | 49.2 / 74.2 |
| memory: open / after typing and scrolling / at the end | 59 / 34 / 49 MB | 74 / 72 / 74 | 79 / 243 / 74 | 72 / 58 / 95 |

Chosen: TextKit 1, as on the Mac. TK2 loses a whole frame budget many times over: keystrokes of 202 ms and scroll
frames of 233 ms on 10M, every keystroke ~50 ms after a note switch or a big paste. TK1 never left the budget while
typing or scrolling. Findings that shape ios/ (each with its why in ios/app/Editor.swift):
- Never swap a storage under one UITextView: afterwards `text` and `textStorage` still answer for the old storage
  (12 characters) while layout and typing use the new one (10 M). One view per note, the six most recent kept.
- Pin the view's typesetting language (`traitOverrides.typesettingLanguage`): UITextView compares old and new with
  isEqualToString:, so the default nil reads as a change on every trait change and walks every attribute run of the
  text, which also forces the lazy font fixing of the whole text (~400 ms for 10M the first time). The first entry
  into a window still runs it once per note (the 142 ms open of 10M).
- Paste, cut and undo write into the storage directly: UITextInput's insert path is ~120 times slower (5.7 s for
  3 M characters), the same in both engines.
- Select all is the keyboard's cost, not layout: with the keyboard up, UIKit's
  `_UIKeyboardStateManager utlizeEuclidModelForDictationReplacement` word-tokenizes the whole old selection on every
  selection change (~600 ms at 3 M and at 10 M on the phone); with the keyboard down the same change takes 0.1 ms.
  No public API avoids it; Apple's own text views pay it too.
- Simulator (M3 Pro, iOS 27.2) agrees in direction; its absolute numbers are not the phone's (select all 213-492 ms,
  TK1 open of 10M 210 ms).

The app itself on the same iPhone 15 Pro (ios/tests/PhoneTests.swift, the app's Editors and History, 2026-11-25; W&P /
10M; median / max where two numbers): open the note from another 16 / 163 ms (the 10M first entry is the one-time
attribute walk above); keystroke at start 2.4 / 5.3 and 4.2 / 6.0, middle 3.3 / 8.7 and 4.6 / 11.5, end 2.2 / 3.7 and
6.3 / 8.3 ms; finger scroll 0.1 / 3.0 and 0.1 / 1.9 ms; paste the whole text into a new note 26 / 51 ms, typing right
after it 2.3 / 2.8 and 6.9 / 11.9 ms; undo of that paste 12 / 12 ms, redo 28 / 28 ms (1 280 ms on 10M before redo
stopped selecting a restored text over 100 000 characters: the keyboard's word count again); switch to a note and back
16-18 ms; text size step 39 / 95 ms; select all 524 / 778 ms and deleting that selection 101 / 343 ms (both the
keyboard's word count of the selection); memory with both notes open, scrolled, pasted and undone 151 / 516 MB.
