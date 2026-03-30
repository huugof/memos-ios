# Backlog

## Editor Bugs

### Bold font persists after tags/headers
When you return a line after typing a tag or header, bold font persists. Clears after closing and reloading the note, but annoying during editing.

**Status:** Closed
**Notes:**

---

### Manually typed checkbox indent is wrong
If you manually type a checkbox, the indent of the first character after the box is wrong.

**Status:** Closed
**Notes:**

---

### List/task editing causes shifting behavior
Editing earlier lists/tasks creates a strange effect where new tasks get added or following checkboxes shift.

**Status:** Closed
**Notes:**

---

## Notes Lifecycle

### Note disappears after first send
When you first send a note it disappears from the list until the refresh button is clicked manually.

**Status:** Closed
**Notes:**

---

### Edited server notes should be marked as draft
When editing a note that is already on the server, the note should be tagged as a draft until it's sent back to the server.

**Status:** Closed
**Notes:**

---

### New-note-after-X-minutes feels choppy
The current behavior feels choppy — the note clears real quick. Consider whether the timing/transition needs smoothing or rethinking.

**Status:** Closed
**Notes:**

---

## Notes Screen & Navigation

### Unified auto-sync editor + enhanced notes sheet
Rethink the notes screen, tag navigation, and new-note hit target together as one redesign.

**Status:** Open
**Notes:**

#### Goal
- Notes auto-sync to server as you type (debounced ~2s to avoid the slowness we hit before)
- Offline changes queue locally and sync when connectivity returns
- The big send/save button becomes a **"New Note" button** (large hit target) — in both editor and notes sheet
- Small status indicator in top bar: saved, saving, pending, offline
- No UX distinction between new notes and editing existing notes

#### Editor changes (DraftEditorView + ServerMemoEditorView)
- Remove send/save button → replace with large "New Note" button (same prominent circular style)
- New note button: archives current note if it has content, creates fresh draft
- Add 2-second debounce for server sync after typing stops (local DB save stays at 350ms)
- Both editors get identical auto-sync behavior — only sync when there's actual content (no blank memos)
- Flush pending sync on app background/disappear

#### Status indicator (EditorRootView top bar)
- No indicator = everything synced
- "Saving..." = actively sending/saving
- "Saved" = just synced (fades after ~2s)
- "Pending" = queued, waiting for sync/connectivity
- "Offline" = last attempt failed due to network
- Derived from existing queue controller published states

#### Notes sheet (AllNotesSheetView)
- Add prominent "New Note" button in header (larger hit target than current icons)
- Add horizontal scrolling tag bar between search bar and list
- Tags from server (`fetchTags()`) + extracted from local drafts (`NotesSearchQuery.extractTags`)
- Tapping a tag chip sets/clears search filter (reuses existing `applyTagFilter` logic)

#### Architecture notes
- Internal model stays split (Draft vs ServerMemoEditDraft) — backend needs POST vs PATCH. UX hides this.
- No network reachability monitor needed — existing retry-with-backoff handles offline gracefully.
- May clean up obsolete settings: `quickCaptureMode`, `keepTextAfterSend`, `markSentOnSuccess`

#### Files to modify
- `Views/DraftEditorView.swift` — remove send, add new-note, add server sync debounce
- `Views/ServerMemoEditorView.swift` — remove save, add new-note, add local + server sync debounce
- `Views/EditorRootView.swift` — wire auto-sync, status indicator, notes sheet new-note + tag bar
- `Views/Components/FloatingSendPill.swift` — repurpose as NewNoteButton
- `Services/DraftSendService.swift` — handle auto-sync trigger
- `Storage/AppSettings.swift` — clean up obsolete settings

---

## New Features

### Widget
Build an iOS widget for the app.

**Status:** Open
**Notes:**

---

### Swipe to share a note
Add swipe gesture to share a note from the list.

**Status:** Open
**Notes:**

---

## Integrations

### Other note system APIs
Add support for other note system APIs — both adding new notes and working with existing notes.

**Status:** Open
**Notes:**
