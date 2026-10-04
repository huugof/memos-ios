# Attachment Thumbnails — Design

**Date:** 2026-10-03
**Status:** Implemented — device checklist pending. Tap-to-preview for vault attachments added 2026-10-04 (see the last section).
**Scope:** One feature, one plan.

## Goal

A note shows a small thumbnail of what is attached to it: a tile on its row in the history
list, and a strip above the editor bar while it is open. Pictures show a real thumbnail;
other files show a type icon and name. It works for both destinations — vault images, and
Memos images and files.

## Decisions (brainstorming, 2026-10-03)

| Question | Decision |
|---|---|
| Where | History rows **and** the opened note |
| Non-image files | Type icon + name. No real previews |
| Memos attachments held on the memo itself (not linked in its text) | Included |
| Approach | Attachment refs live in the index / summary; one shared loader turns a ref into pixels at display time |

Rejected approaches: **resolve at index time** — an image that syncs after its note, or
moves, changes nothing in the `.md`, so the mtime/size diff never refreshes the entry and
thumbnails go stale; **pre-render thumbnails while indexing** — decodes every changed
note's images (more iCloud download pressure), needs its own invalidation, and Memos plus
the editor strip still need an on-demand path.

## Non-goals

- Tapping a history-row tile. Row tiles are display-only.
- Previews of Memos attachments, and audio/video posters. (Vault attachments in the editor strip preview
  when tapped — see the last section.)
- Attaching non-image files to vault notes (still declined: "File attachments aren't
  supported for vault notes yet.").
- Animated GIFs (first frame only). SVG is shown as a file tile.
- Removing an existing attachment from the strip (delete its line in the text instead).
- A persisted vault-wide image index.
- Fetching anything from a host other than the configured Memos server.
- Changing which Memos notes appear in history (see "Known limitations").

## Today — what the design rests on

**In this repo**

- Quoote embeds attachments in the note text. Vault images are written to
  `AppSettings.vaultAttachmentsFolder` and linked `![[<name>.jpg]]`
  (`NoteEditorView.handleImageSelected`). Memos images are linked
  `![](<base>/file/attachments/<uid>/image.jpg)`, Memos files `[<name>](<url>)`.
- `createMemo` sends only `content`, so Quoote's uploads are never linked to the memo
  server-side. The file server serves an unlinked attachment only to its creator
  (`checkAttachmentPermission`), so the Bearer token is required.
- A thumbnail exists only in the editor's pending bar, before send. After that the editor
  shows raw markdown and the history row shows nothing.
- History rows render from `VaultIndexEntry` (no body — reading files per row would force
  iCloud downloads), `ServerMemoSummary`, or `Draft`.
- `NoteExcerpt` strips `![[…]]` and `![](…)` but leaves `[name](url)` as raw text. An
  image-only vault note's row falls back to its raw title (`![[x.jpg]]`).
- `ServerMemoSummary` keeps only `attachmentCount` from the server's per-memo attachment
  list. `UnifiedNote.hasAttachments/hasImages/hasFiles` exist and nothing calls them.

**Memos** (verified against usememos/memos `main`; the user's server version may differ)

- `Memo.attachments` is a list separate from `content`: `name` (`attachments/{uid}`),
  `filename`, `type` (MIME), `size`, `externalLink`. The web editor links attachments to
  a memo through it (`toAttachmentReferences`, `MemoEditor/services/memoService.ts`), not
  through the text.
- Files are served at `GET /file/attachments/{uid}[/{filename}]`. The handler reads the
  `Authorization` header (and cookie). Non-public memos and unlinked attachments answer
  401 without it.
- `?thumbnail=true` returns a JPEG of at most 600 px for png/jpeg/heic/heif/webp, and the
  original for anything else or when it cannot thumbnail.
- Private attachments are sent `Cache-Control: private, no-store`, so URLSession never
  caches them.

## Architecture

```
note text ─┐
vault index ├─ NoteAttachments.parse / merged ─► [NoteAttachment]
memo.attachments ┘                                     │
                                          UnifiedNote.attachments
                                       ┌───────────────┴───────────────┐
                                  NoteRowView                     AttachmentBar
                                       └──── AttachmentTile ◄──────────┘
                                                   │
                                      AttachmentThumbnailLoader
                       ┌───────────────────────────┴───────────────────────────┐
        vault: resolve → VaultFileStore → ImageIO        Memos: origin check → disk cache → fetch → ImageIO
```

## Design

### 1. Finding attachments

**Model.** `NoteAttachment` (Codable, Hashable): `target`, `name`, `kind` (`.image` | `.file`).

`target` is where the bytes live, as written:

- a vault name or path (`photo 1.jpg`, `attachments/a.png`) — taken literally from a
  wikilink, percent-decoded from a markdown embed;
- an absolute `http(s)` URL;
- a Memos-relative path: `/file/attachments/{uid}/{filename}` or `/o/r/{id}/{filename}`.

Identity (the dedupe key): the URL *path* for URL and Memos-relative targets — so a link
embedded in the text and the same attachment from the server's list are one attachment —
and the target string otherwise.

**Parser.** `NoteAttachments.parse(_ text: String) -> [NoteAttachment]` — pure, in
`ViewModels/`, document order, duplicates collapse to the first.

1. `![[target|…#…]]` embeds. Target = text before the first `|` or `#`, trimmed. It is an
   attachment only if its last path component has an extension of 1–5 alphanumerics
   containing a letter, other than `md`/`markdown` — so note transclusions and dotted note
   names (`Meeting 10.3`) are skipped. Kind: image for png, jpg, jpeg, gif, heic, heif,
   webp, bmp, tif, tiff, avif; otherwise file. Name = last path component.
2. `![alt](target)` images. Target = the text in the parentheses up to the first
   whitespace (or inside `<…>`). A scheme other than http/https (`data:`, `file:`, …) is
   ignored. Kind: file only if there is an extension and it is not an image extension;
   no extension → image, because it was written as an image embed. Name = percent-decoded
   last component of the path.
3. `[name](url)` links, not preceded by `!`, whose path starts with `/file/` or `/o/r/` —
   absolute URL or Memos-relative. Kind from the name's extension (image extension →
   image; otherwise, including none, → file). Name = the link text, else the last path
   component. Ordinary web links are not attachments.

Code spans and fences get no special handling (same as `NoteExcerpt`).

`NoteAttachments.merged(_:_:)` concatenates two lists and dedupes by identity.
`NoteAttachments.tile(from:)` picks the row's tile: the first `.image`, else the first
`.file`, plus `extra` = total − 1; nil for an empty list.

**Vault index.** `VaultIndexEntry.attachments: [NoteAttachment]?`, filled by `make(from:)`
from the note body. `nil` means "not scanned".

- `VaultIndex.diff` treats `nil` like `needsContent`: the entry is re-read once in the next
  refresh. Existing notes backfill in the background while rows keep rendering from the old
  index — no blank list, no index-version bump.
- The placeholder entries `performRefresh` builds for evicted iCloud notes carry the prior
  entry's `attachments`, and stay `nil` until the file downloads.
- An existing `vault_index_v2.json` decodes with `nil` (synthesized `Codable` on an
  optional, same precedent as `needsContent`).

**Memos summaries.** `ServerMemoSummary.attachments: [NoteAttachment]?` — optional, so an
existing `memo_cache_v1.json` still decodes. `MemosClient.extractMemoSummary` fills it from
the memo's `attachments` (and `resources` / `resourceList` for older servers). Each element
with a non-empty `filename` becomes `target = "/file/{name}/{filename}"` (or
`/o/r/{id}/{filename}` when it carries only a numeric `id`), `name = filename`, kind from
`type`: `image/*` except `image/svg+xml` → image, otherwise file. `attachmentCount` is
unchanged. `ServerMemosStore.mergeMemo` keeps the incoming list when it has one, else the
existing one.

**Note-level API.** `UnifiedNote.attachments`:

- `.vault` → `entry.attachments ?? []`
- `.local` → `parse(draft.text)`
- `.server` → `merged(parse(content), memo.attachments ?? [])` (text-embedded first)

It replaces the unused `hasAttachments` / `hasImages` / `hasFiles`.

**Excerpt and row text.**

- `NoteExcerpt` also drops `[name](url)` links to Memos file paths (shared pattern with the
  parser). A vault note re-read by the backfill gets the cleaned preview too.
- `UnifiedNote.excerpt` for a vault note no longer falls back to the raw title when its
  preview is empty and it has attachments.
- When the excerpt is empty and the row's tile is a file, the excerpt is that file's name.

### 2. Loading thumbnails

`AttachmentThumbnailLoader` — `Services/`. Dependencies are injectable for tests; the app
uses a `shared` instance.

- `cachedImage(for:notePath:) -> UIImage?` — synchronous memory-cache lookup, no I/O, so a
  row's first render does not flash its placeholder.
- `thumbnail(for:notePath:) async -> UIImage?` — an image of at most 192 px (the 56 pt tile
  at 3x) or `nil`. Only `.image` attachments are loaded; files never reach the loader.
  `notePath` is the note's vault-relative path when it has one.

**Vault targets** (anything that is not a URL or a Memos-relative path). Targets with a
`..` component or a leading `/` are rejected. Otherwise they resolve in order, each step
accepting the file or its iCloud placeholder:

1. `{attachmentsFolder}/{target}`
2. `{target}` from the vault root
3. `{noteFolder}/{target}`, when `notePath` is known
4. fallback: walk the vault (skipping `.obsidian`, `.trash`, hidden items) for the first
   file with that name, case-insensitively

Resolutions and misses are remembered for the session; a miss is retried after 60 s, so an
image that syncs after its note appears later.

Reads go through `VaultFileStore` (new: resolve, find, thumbnail) inside
`VaultBookmarkStore.withAccess`, off the main thread: a coordinated read, then ImageIO
`CGImageSourceCreateThumbnailAtIndex` (max pixel 192, honoring EXIF orientation), so the
full-size bitmap is never held. Vault thumbnails are not disk-cached: a local read plus a
downsample is fast, and only the memory cache sits in front. An evicted iCloud file is
never read — that would block on a download. The loader calls
`startDownloadingUbiquitousItem` (via `VaultFileStore.requestDownload`) and returns `nil`;
the next appearance retries.

**Remote targets.**

- URL = the absolute target, or the configured `endpointBaseURL` + the Memos-relative
  target.
- Origin rule: fetch only when scheme, host and port equal the configured Memos origin
  (host compared case-insensitively, default ports normalized). Any other host gets no
  request — no token leak, no tracking pixel from a pasted web image. Endpoint or token
  unset → `nil`. An `http` origin is fetched only if `AppSettings.allowInsecureHTTP`.
- `GET` with `Authorization: Bearer <token>` (`KeychainTokenStore.getToken()`), 15 s
  timeout. Paths under `/file/attachments/` first try `?thumbnail=true` (keeping any
  existing query); a non-2xx or undecodable answer falls back to the plain URL, which
  covers older servers and the original-instead-of-thumbnail case. Bodies are capped at
  10 MB and aborted beyond it.
- The result is downsampled with ImageIO to at most 192 px and stored as JPEG (quality 0.8)
  in `Caches/AttachmentThumbnails/{sha256(url)}.jpg`, capped at about 50 MB, oldest
  trimmed at loader start and every 20 writes. A disk hit short-circuits the network, so
  thumbnails keep working offline.

**Both.**

- A cost-limited (~32 MB) in-memory `NSCache` sits in front.
- Identical in-flight loads share one task, cancelled when no waiter is left. At most 4
  loads run at once; the rest wait and drop out if cancelled.
- Vault images are revalidated by mtime on the async path: a replaced file reloads.
- Any failure is silent and remembered for 60 s in memory, so a failing attachment is not
  re-requested on every re-render. The view keeps its icon.

### 3. Showing them

**`AttachmentTile`** — `Views/Components/`. 56×56, corner radius 8, `secondarySystemFill`
background (the pending bar's dimensions).

- Image: SF Symbol `photo` until loaded, then the thumbnail (`scaledToFill`, clipped)
  crossfading in over 0.15 s. Seeded from `cachedImage`, loaded in `.task(id:)`.
- File: a type icon chosen by UTType (PDF, text, audio, video, archive, generic) with the
  uppercase extension.
- Optional "+N" badge, bottom-trailing (capsule, `.ultraThinMaterial`, `.caption2.bold`).
- VoiceOver: "Image attachment" or "File: {name}", plus "and N more".

**`NoteRowView`.** `HStack(alignment: .center, spacing: 12)`: the existing text column,
then the tile at the trailing edge (from `NoteAttachments.tile(from:)`). The text column
narrows beside it. Notes without attachments render exactly as today.

**`AttachmentBar`** — `Views/Components/`, extracted from
`NoteEditorView.pendingAttachmentsBar` (the view is 984 lines). One horizontally scrolling
glass bar, 72 pt as now: existing attachments first (a vault file previews when tapped), then pending images and
files (✕ and upload spinner as now). Images are the same 56 pt tiles; files the same chip
(type icon + name, two lines, 80 pt max). It shows when either list is non-empty, and the
editor's bottom padding follows.

Existing attachments = `parse(current text)`, merged with `memo.attachments` for a Memos
note (looked up in `ServerMemosStore`). Recomputed when the text changes, debounced 300 ms,
so deleting a line removes its tile.

**Display only in the history row.** Tapping a row opens the note as before; row tiles take no taps. In the
editor strip a vault attachment opens a preview when tapped (last section).

## New and changed files

New: `ViewModels/NoteAttachments.swift` (model + parser), `Services/AttachmentThumbnailLoader.swift`,
`Views/Components/AttachmentTile.swift`, `Views/Components/AttachmentBar.swift`, and tests.

Changed: `Services/Vault/VaultIndex.swift`, `Services/Vault/VaultStore.swift`,
`Services/Vault/VaultFileStore.swift`, `Services/MemosClient.swift`,
`Services/ServerMemosStore.swift`, `ViewModels/UnifiedNote.swift`,
`ViewModels/NoteExcerpt.swift`, `Views/Components/NoteRowView.swift`,
`Views/NoteEditorView.swift`.

Unchanged: sending and saving (`updateMask=content` leaves a memo's own attachments alone),
the vault write path, `Draft`, the Memos upload path.

## Error handling

Silent everywhere. An unresolvable, evicted, offline, unauthorized, oversized or
undecodable attachment leaves its tile on the icon. No banners, and nothing thrown out of
the loader. A memo whose attachment list cannot be parsed gets `attachments = nil`, which
is today's behaviour.

## Testing (XCTest)

- `NoteAttachmentsTests` — each syntax; `|size` and `#page` suffixes; note transclusions and
  dotted note names skipped; non-http schemes ignored; ordinary links ignored; Memos file
  links; document order; dedupe, including absolute-vs-relative URL; kinds; `tile(from:)`.
- `VaultIndexTests` — `make(from:)` fills attachments; `nil` → `needsRead`; `[]` →
  unchanged; legacy JSON decodes to `nil`. The existing helper builds entries without the
  field and must pass `attachments: []`.
- `NoteExcerptTests` — Memos file links dropped, ordinary links kept.
- `UnifiedNoteVaultTests` — an image-only vault row shows no raw title; a file-only note
  shows the file name; `.server` merges both sources.
- `MemosClientParsingTests` — `attachments` (modern), `resources` (older), numeric `id`, a
  missing filename skipped, MIME → kind; `ServerMemoSummary` round-trips, and legacy cache
  JSON decodes.
- Loader (temp-dir vault, stub `URLProtocol`, injected token and endpoint) — resolution
  order and `..` rejection; placeholder → download requested, no read; origin rule (foreign
  host → zero requests, token only on the Memos origin); `?thumbnail=true` then fallback;
  10 MB cap; output ≤ 192 px; disk hit → no request; failure remembered 60 s; in-flight
  sharing and cancellation.
- Needs a device (the simulator cannot reach it, and there is no tap automation): an evicted
  iCloud image; Memos thumbnails offline from the disk cache; a private memo with the
  token; scroll smoothness over hundreds of rows; a large HEIC.

## Risks and known limitations

- The backfill re-reads every vault note once — the same I/O as the first index build —
  in the background.
- The vault-wide walk happens only on a miss, and is cached.
- A server older than the attachments API may serve thumbnails differently; the plain-URL
  fallback covers it. The Memos facts above were checked against `main`, not the user's
  server.
- A picture linked from another host shows the generic tile — by design.
- **A Memos note with no text stays hidden from history, even if it has attachments.**
  `UnifiedNote.merge` drops text-less memos, and `memoForEditing` rejects them ("Full note
  content is unavailable for editing"). Showing them is a separate change touching both.
  Quoote's own image-only notes are unaffected: their text holds the link.

## Open questions for planning

None blocking. The plan decides how the in-flight/concurrency gate is built and which
mechanism enforces the download cap (a delegate or a streamed read).

## Follow-up: tap to preview a vault attachment (2026-10-04)

Tapping an existing vault attachment in the editor's strip opens it in QuickLook over the editor. Memos
attachments, the history-row tile, and unsent attachments are not tappable yet.

- QuickLook reads from another process, and the vault is only open inside `VaultBookmarkStore.withAccess`, so the
  file is copied first: `VaultFileStore.copyAttachment(at:into:)` into `tmp/AttachmentPreviews/<uuid>/<name>`,
  driven by `AttachmentPreviewFiles` (locate as the thumbnails do, wait for an evicted iCloud file — polling, 30 s —
  and delete the copy when the preview closes; copies left by a crashed run are swept after an hour).
- `AttachmentPreviewer` is the state the editor binds to `.quickLookPreview`: the copy being shown, the tile to put a
  spinner on once a load takes over 250 ms, and a sentence for the editor's banner on failure. The last tap wins.
- The editor treats the preview as something it presented. Its text view losing focus closes the sheet and commits,
  unless something it presented took the keyboard, so `isCoveredByPresentation` includes the preview and the editor
  drops focus when it opens (the keyboard would otherwise stay over it). SwiftUI presents QuickLook `overFullScreen`,
  so the sheet does not disappear and its `onDisappear` commit does not run; `AttachmentPreviewPresentationTests`
  fails if a system update changes that.
- Not verified without a phone: an evicted iCloud file, the keyboard going away and coming back, VoiceOver.
- Left for later: Memos attachments (an authenticated download of the full file; an S3-backed server redirects off
  the configured host, which the thumbnails also refuse), the history-row tile, unsent attachments.
