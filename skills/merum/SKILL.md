---
name: merum
description: "Lists, reads, and creates plain-text notes in Merum (a Mac and iPhone notes app synced through iCloud) via merum-cli. Use when reading a note the user keeps in Merum, saving text into a new Merum note, or customizing Merum."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with Merum installed (/Applications/Merum.app)."
---

# Merum

Reads and adds plain-text notes from the command line. Notes live in `~/Library/Application Support/Merum/` (`notes.json`, `Notes/<id>.txt`, UTF-8), synced through the user's iCloud.

## Locate the CLI

Use the first that exits 0:

```sh
merum-cli --help
/Applications/Merum.app/Contents/MacOS/Merum --help
```

If neither works, tell the user Merum is not installed and stop.

## Common tasks

1. **List the notes** in the app's order (number, name, characters):
   ```sh
   merum-cli list
   merum-cli list --json
   ```
2. **Read a note** by its number in the list (from 1) or its name (exact, then any case):
   ```sh
   merum-cli cat 1
   merum-cli cat "First Note"
   ```
3. **Make a new note** from standard input (default name such as «Third Note», or a name given); it goes last in the manual order and does not change what the user's window shows:
   ```sh
   pbpaste | merum-cli new
   printf '%s' "$TEXT" | merum-cli new "Meeting"
   ```
4. **Status** (version, whether the app runs, notes folder, count, sort, text size):
   ```sh
   merum-cli status --json
   ```

## Rules

- Never edit the files in `~/Library/Application Support/Merum/` directly: while Merum runs it owns them, and sync would see half a change. `merum-cli` goes through the running app (unsaved typing included) and through the same core when it does not run.
- There is no delete or edit command on purpose: changing or removing the user's notes is the user's own act in the app (⌘Z there undoes it).

## Rebuilding from source

Clone `https://github.com/geragarazagh/merum`, read `AGENTS.md`, edit, and run `./build` (Xcode Command Line Tools are enough for a local ad hoc build; full Xcode for the icon's Assets.car and for Developer ID builds).
