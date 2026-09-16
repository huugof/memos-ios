# Obsidian Vault Destination — Design

**Date:** 2026-09-16
**Status:** Approved for planning
**Scope:** Project #1 of 4 (see "Out of scope" below)

## Goal

Let MemoChat write and read notes as Markdown files in an Obsidian vault, as an
alternative to the self-hosted Memos server. The user picks one destination; it is
active until they change it.

The vault destination is a full read/write browser: the history drawer lists real vault
files, opening one loads it, editing saves it back. Notes carry YAML frontmatter that
MemoChat maintains without disturbing keys it does not understand.

## Why file-based, and why only one way

iOS offers three routes into an Obsidian vault:

1. **Security-scoped folder bookmark** — the user picks the vault with
   `UIDocumentPicker`, the app persists a bookmark and reads/writes files directly.
   Works for vaults in iCloud Drive, On My iPhone, and third-party file providers.
2. **`obsidian://new` URL scheme** — launches Obsidian on every capture. Incompatible
   with an app whose entire point is staying in the editor.
3. **Local REST API plugin** — requires a desktop instance running. Not viable on the go.

This design uses (1). (2) and (3) are rejected.

## Non-goals

- Migrating existing Memos notes into the vault, or vice versa.
- Writing to both destinations at once.
- Rendering Obsidian-specific syntax (wikilinks, embeds, Dataview) in the editor.
- Multiple vaults, or multiple Memos accounts.
- Resolving conflicts in-app beyond writing a conflict copy.

## Out of scope (separate projects)

This spec deliberately covers only the vault destination. Three related tracks are
independent and get their own specs:

1. **Frontmatter editor UI** (phase 2) — arbitrary user-defined key/value editing.
   This spec delivers frontmatter *serialization*, which phase 2 builds on. Building
   the editor before files exist would be building against nothing.
2. **SiloNote-inspired UI** — drawer stats (Notes/Tags/Days), contribution heatmap,
   editor inline toolbar row. Independent of destination.
3. **Launch speed** — `MemosIOS/Services/LaunchTrace.swift` instrumentation was added
   2026-06-28 and the cold-launch measurement was never taken. Independent.

## Architecture

### The seam

`Draft` (SwiftData) is already a destination-agnostic local buffer: it holds text before
it goes anywhere and survives backgrounding. The destination split goes *after* `Draft`,
not through it.

```
compose → Draft (unchanged, crash-safe buffer)
            │
            └→ DestinationRouter (reads AppSettings.destinationKind)
                 ├─ .memos → sendQueue.enqueue(draft)     [existing path, unchanged]
                 └─ .vault → VaultStore.write(draft)      [new, no queue]
```

`MemosDestination` delegates to the existing `DraftSendQueueController`,
`ServerMemoSaveQueueController`, and `ServerMemoDeleteQueueController` without modifying
them. `VaultDestination` needs none of that machinery.

### Why the vault path has no queue

Network writes are transient failures deserving retry and backoff. File writes either
succeed or fail immediately and structurally — a stale bookmark is not fixed by
retrying in 15 seconds. Getting bytes from the local file to iCloud is the OS's job,
not the app's.

Consequence: `VaultDestination` is materially *less* machinery than `MemosDestination`,
and the existing queue models stay Memos-specific rather than being generalized into an
abstraction that fits neither.

### New files — `MemosIOS/Services/Vault/`

| File | Responsibility | Depends on |
|---|---|---|
| `VaultBookmarkStore.swift` | Persist/resolve the security-scoped bookmark; detect staleness; balance `startAccessingSecurityScopedResource` / `stopAccessing`. | Foundation |
| `VaultFileStore.swift` | Enumerate, read, write, delete `.md` files via `NSFileCoordinator`. The only file-touching code in the app. | `VaultBookmarkStore` |
| `Frontmatter.swift` | Parse a `---` block into ordered key → raw-text spans; splice edits back. Pure value type, no I/O. | Foundation |
| `VaultNote.swift` | File-backed note: relative path, frontmatter, body, modDate, size. | `Frontmatter` |
| `VaultIndex.swift` | On-disk index of path → title, preview, tags, modDate, size. Mirrors the existing `MemoCache` pattern. | `VaultNote` |
| `VaultStore.swift` | `@MainActor ObservableObject`. In-memory list, refresh, upsert — the `ServerMemosStore` analogue, same shape the views already consume. | all of the above |

`MemoChat/Services/NoteDestination.swift` holds the `NoteDestination` protocol, the
`DestinationKind` enum, and `DestinationRouter` — the single place that reads
`AppSettings.destinationKind` and dispatches a send to either the queue or the vault
store. Views never branch on destination themselves; they call the router.

### Changed files

- `MemoChat/ViewModels/UnifiedNote.swift` — add `.vault(VaultNote)` case. Existing
  computed `content` / `title` / `date` / `tags` extend naturally.
- `MemosIOS/Storage/AppSettings.swift` — add `destinationKind`, `vaultBookmark`,
  `vaultNotesFolder`, `vaultAttachmentsFolder`.
- `MemoChat/Views/ComposeRootView.swift` — start the queues *or* the vault store.
- `MemosIOS/Views/SettingsView.swift` — destination picker, vault folder picker,
  subfolder fields.
- `MemoChat/Views/NotesListView.swift`, `MemoChat/Views/NoteEditorView.swift` — route
  by destination.

### Explicitly unchanged

`PlainNoteEditor`, `NoteListEditing`, `TagExtractor`, `DraftStore`, `MemosClient`, all
three queue controllers, `MemoCache`.

This boundary means a later decision to go vault-only deletes `MemosDestination` and
~1000 lines of client code without the compose path noticing.

## File format

### Naming

`YYYY-MM-DD HHmm.md` in the configured notes subfolder, matching SiloNote's model.
Timestamp names never collide, and editing the first line never requires renaming a
file (which would break inbound `[[wikilinks]]`).

Collision fallback: if the filename exists, append ` 2`, ` 3`, … before the extension.

### Frontmatter

Default keys, all app-maintained:

```yaml
---
title: First line of the note
created: 2026-09-16T21:30:03Z
updated: 2026-09-16T21:34:11Z
tags: [inbox, ideas]
---
```

- `created` / `updated` — ISO-8601. `updated` is rewritten on every save.
- `title` — the first non-empty body line, stripped of leading `#`. Unlike
  `UnifiedNote.title` it does **not** fall back to a placeholder: if the body is empty
  the key is omitted entirely rather than written as `"New Note"`.
- `tags` — mirrored from inline `#tags` in the body (see below).

### Frontmatter editing strategy: surgical splice, not YAML round-trip

The requirement is to preserve keys, comments, and ordering the app does not understand.

`Frontmatter` parses the block into an **ordered list of key → raw text span**. On save,
only the spans for keys the app actually changed are rewritten; everything else is
spliced back byte-identical. Unknown keys, comments, blank lines, quoting style, and
nested structures survive because they are never re-serialized.

The rejected alternative — parse to a dictionary with Yams and re-emit — normalizes the
file on every save: comments die, key order shifts, quoting changes. Against a vault
synced to desktop Obsidian that produces a noisy diff on every capture. It would also
introduce the first third-party dependency into a currently dependency-free project.

Edge cases the parser must handle, each with a test:
- No frontmatter block at all (bare Markdown file).
- `---` appearing inside the body (horizontal rule) — only a block at byte 0 counts.
- Empty frontmatter block (`---\n---`).
- CRLF line endings.
- A `tags` value in block-sequence form (`- item` lines) rather than inline `[a, b]`.
- Unterminated opening `---` — treat the whole file as body, write no frontmatter.

### Tags

Inline `#tags` stay in the body **and** mirror into the frontmatter `tags` array.
Obsidian indexes both, so search works either way.

**Drift rule:** `tags` is app-maintained. On save it is set to the inline body tags, so
deleting `#foo` from the body removes it from frontmatter. When the phase-2 frontmatter
editor lands, manually-added tags union in. This rule is what keeps the two
representations from diverging.

### Attachments

Images are written into the configured attachments subfolder and referenced as
`![[filename.png]]` — Obsidian's native form, which resolves regardless of note folder
depth. Filenames follow the note's timestamp plus an index: `2026-09-16 2130 1.png`.

Non-portability outside Obsidian is accepted; the destination is named for Obsidian.

## Reading the vault

### The materialization problem

Files in an iCloud Drive vault may not be present locally. Directory enumeration yields
names and modDates cheaply, but *content* for a `.notDownloaded` file requires
`startDownloadingUbiquitousItem(at:)` and a wait. `NoteRowView` renders title and
preview, which need content. Downloading an entire vault to draw a list is unacceptable.

### The index

`VaultIndex` persists path → title, preview, tags, modDate, size, following the existing
`MemoCache` pattern.

1. At launch the drawer renders from the index — instant, no I/O wait, no network.
2. A background pass enumerates the folder (metadata only) and diffs against the index
   by modDate and size.
3. Content is downloaded and parsed only for files that changed, are new, or are tapped.

Because there is no network round-trip, vault mode should launch *faster* than Memos
mode.

### Live updates

Polling on `scenePhase == .active`, plus the existing 45s `autoSyncLoop`, reusing the
`refreshIfStale` pattern already in `ComposeRootView`.

`NSFilePresenter` on the vault directory is rejected: it is chatty, and its behavior
across third-party file providers is inconsistent. Polling matches the app's existing
"invisible sync" model and is far less code.

### Write cadence

Debounced ~2s after typing stops, plus a flush on view disappear and on app background —
matching the debounce already specified for server edits. Per-keystroke writes would
thrash iCloud sync.

## Conflict handling

New captures cannot collide: the filename is a fresh timestamp.

The only conflict surface is editing a note that also changed externally. Before writing
an existing file, compare its current modDate and size against the values read when the
note was loaded.

On mismatch: write the in-app version to `<name> (conflict YYYY-MM-DD HHmm).md`, leave
the external version untouched, and show a non-blocking banner. This is the
Dropbox/Obsidian Sync convention. It never loses data and never interrupts typing.

Rejected: prompting (fires at the worst possible moment in a quick-capture app) and
last-write-wins (silently eats desktop edits).

## Error handling

Vault failures are structural, not transient, so each surfaces a message rather than
entering a retry loop.

| Failure | Handling |
|---|---|
| Bookmark stale / vault moved | Non-blocking banner → "Reconnect vault" → re-open picker. Bookmarks go stale on restore-from-backup, so this will occur in normal use. |
| Folder access revoked | Same path. A save must never fail silently. |
| Disk full / write error | Leave the `Draft` unarchived so the text survives; surface the error. |
| File deleted externally | Drops out of the index on next reconcile. If currently open, it saves as a new file rather than resurrecting the path. |

In every case `Draft` remains the buffer, so no user text is lost to a failed write.

## Testing

**Unit-testable (XCTest, existing `MemosIOSTests` target — 28 tests today):**

- `Frontmatter` parse/splice round-trips, including every edge case listed above. This
  is where the real risk lives and it needs no vault and no simulator.
- Filename generation, including collision fallback.
- Tag mirroring and the drift rule.
- `VaultIndex` diffing by modDate/size.
- `VaultFileStore` against a `FileManager` temp directory, not a real vault.

**Manual device verification (not unit-testable, called out explicitly in the plan):**

- Bookmark persistence across app restart and across device restore.
- iCloud materialization of a `.notDownloaded` file.
- Conflict copy generation against a real desktop Obsidian edit.
- Behavior with a vault in a third-party file provider (Working Copy, Dropbox).

## Settings

- `destinationKind` — Memos or Vault. One active at a time.
- Vault folder picker (`UIDocumentPicker`, folder mode).
- Notes subfolder — default: vault root.
- Attachments subfolder — default: `attachments`.

Switching destinations migrates nothing. Memos notes stay in Memos, vault notes stay in
the vault, and the drawer shows whichever destination is active.

## Open questions for planning

None blocking. Phase-2 frontmatter editing will need a decision on how manually-added
frontmatter tags union with body tags; that belongs in its own spec.
