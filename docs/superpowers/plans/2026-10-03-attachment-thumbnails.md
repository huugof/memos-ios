# Attachment Thumbnails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a thumbnail of each note's attached pictures and files — a tile on its history row, and a strip above the editor bar while it is open — for vault notes and Memos notes alike.

**Architecture:** Attachment references are found in note text by a pure parser, stored in the vault index and on `ServerMemoSummary` (`nil` means "not scanned"), and merged into `UnifiedNote.attachments`. One shared `AttachmentThumbnailLoader` turns a reference into pixels at display time: vault files through `VaultFileStore` (ImageIO downsample, revalidated by modification date), Memos files through `MemosAttachmentFetcher` (pinned to the Memos origin, token sent nowhere else, disk-cached). `AttachmentTile` draws the result; `NoteRowView` and the new `AttachmentBar` place it.

**Tech Stack:** Swift 5 language mode, SwiftUI, Swift concurrency (actors), ImageIO, CryptoKit, URLSession, XCTest, XcodeGen. iOS 26.0. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-03-attachment-thumbnails-design.md` — read it first; this plan implements it and does not repeat its reasoning.

## Checked before handoff

Every code block and every edit in this plan was applied, verbatim and in order, to a throwaway copy of `main` (not this working tree), and the copy was built and tested: it compiles without warnings from the new code and the whole suite passes — **374 tests, 0 failures**. The failing-test steps in Tasks 2 and 13 were confirmed red by reverting just their implementation. What that cannot cover is on the device checklist in Task 15.

## Where the plan fills in what the spec left open

The spec's design stands as written. Planning decided:

- **The concurrency gate** is `AsyncGate`, a small actor whose waiters drop out when their task is cancelled (Task 6).
- **The download cap** is enforced by streaming with `URLSession.bytes(for:)` and abandoning the body the moment it crosses the limit; a declared `Content-Length` over the limit is refused without reading. The limit is a parameter (10 MB in the app) so tests don't need 10 MB bodies (Task 9).
- **The loader is built from four small units**, each with its own tests, instead of one large file: `AsyncGate`, `ThumbnailDownsampler`, `ThumbnailDiskCache`, `MemosAttachmentFetcher`. `AttachmentThumbnailLoader` only orchestrates them.
- **`VaultFileStore`'s new methods live in an extension file** (`VaultFileStore+Attachments.swift`): the struct's file is already 491 lines and its `fileManager` is file-private.
- **The server-list mapping lives in `NoteAttachments.fromServerList`**, which `MemosClient.extractMemoSummary` calls, rather than inline in the 1071-line `MemosClient`.
- Two details the spec implies and the code makes explicit: thumbnails are flattened onto white (JPEG has no alpha, so a transparent PNG would turn into a black box), and a redirect that leaves the Memos origin is not followed (otherwise "any other host gets no request" would have a hole).

## Global Constraints

Every task's requirements include these. Values are copied from the spec.

- **Platform:** iOS 26.0 deployment target; `SWIFT_VERSION: 5.0`; SwiftUI; XCTest. No third-party dependencies.
- **XcodeGen owns the project file.** After adding any `.swift` file run `xcodegen generate` (version 2.44.1 reproduces the committed `Quoote.xcodeproj/project.pbxproj` byte for byte, so the diff is only the new files) and commit the regenerated `Quoote.xcodeproj/project.pbxproj` with the task. Sources under `Quoote/` and tests under `QuooteTests/` are picked up recursively; tests use `@testable import Quoote`.
- **Test command** (replace `<TestClass>` per task; if `iPhone 17 Pro` isn't installed, pick any from `xcrun simctl list devices available`):
  ```bash
  xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:QuooteTests/<TestClass> 2>&1 | grep -E ": error: |Executed|\*\* TEST"
  ```
  The first run after a clean build takes a couple of minutes.
- **Thumbnails:** longest edge at most **192 px** (a 56 pt tile at 3x). In-memory `NSCache` of about **32 MB**. Memos pictures are also kept as JPEG (quality **0.8**) in `Caches/AttachmentThumbnails/{sha256(url)}.jpg`, capped at about **50 MB**, oldest trimmed at loader start and every **20** writes. Vault pictures are not disk-cached.
- **Tile:** 56×56, corner radius 8, `secondarySystemFill` background; "+N" badge bottom-trailing (capsule, `.ultraThinMaterial`, `.caption2.bold`); picture crossfades in over 0.15 s; VoiceOver says "Image attachment" or "File: {name}", plus "and N more".
- **Strip:** one horizontally scrolling glass bar, **72 pt** tall; existing attachments first (read-only), then pending images and files with ✕ and the upload spinner as before.
- **Memos requests:** only to the configured Memos origin (scheme, host and port equal; host case-insensitive; default ports normalized). `Authorization: Bearer <token>` only there. `http` only if `AppSettings.allowInsecureHTTP`. **15 s** timeout. Bodies capped at **10 MB**. Paths under `/file/attachments/` try `?thumbnail=true` first, then the plain URL. Any other host gets no request.
- **Loading:** at most **4** loads at once; identical in-flight loads share one task, cancelled when no waiter is left; any failure is silent and remembered for **60 s**; vault pictures are revalidated by modification date; an evicted iCloud file is never read (a download is requested instead).
- **Errors are never shown:** no banners, nothing thrown out of the loader. A failed tile keeps its icon.
- **Display only:** tiles take no taps. Sending, saving, `Draft`, the vault write path and the Memos upload path are untouched.
- **Git:** work on the branch `feat/attachment-thumbnails` (Task 0). Commit messages use the repo's `feat:` / `fix:` / `docs:` style and end with the Co-Authored-By trailer the harness specifies.

## Review Focus

Inputs and conditions the spec implies but its test list doesn't spell out. Each is pinned by a test named here, in the task that owns the code.

1. **Uppercase extensions, spaces and non-Latin names** — `IMG_0001.JPG`, `Pasted image 20261003.png`, `写真.jpg`: the name is kept as written, only the kind check lowercases, and a Memos file with such a name still gets requested. Pinned by Task 1 `testWikilinkExtensionsAreMatchedCaseInsensitively` and `testEmojiAndNonLatinTextBeforeAnEmbedDoNotShiftIt`, and Task 9 `testFilenamesWithSpacesAndNonLatinLettersStillMakeARequest`.
2. **A Memos server installed under a subpath** (`https://example.com/memos`): a relative `/file/…` target must resolve under the prefix, not at the host root. Pinned by Task 9 `testASubpathInstallKeepsItsPrefix`.
3. **A transparent PNG** (a macOS window screenshot with its shadow) must not turn into a black box once it is cached as a JPEG. Pinned by Task 7 `testATransparentPictureIsFlattenedOntoWhite`.
4. **A server reply that carries no attachment list versus one that lists none**: the first must keep what the app already knew, the second must clear it. Pinned by Task 4 `testAMemoWithoutAListHasNilAttachmentsAndAnEmptyListIsEmpty` and `testAnUpdateWithoutAListKeepsTheOneWeHad`.
5. **A row scrolling away mid-download, and a screenful of rows loading at once**: the request must stop when nobody is waiting for it, and only a few may run together. Pinned by Task 11 `testTheDownloadIsCancelledOnlyWhenTheLastWaiterLeaves` and `testAtMostTheLimitOfLoadsRunAtOnce`.

Also pinned, because it would silently show the wrong picture: the same `![[pic.png]]` in two notes in different folders is two pictures (Task 11 `testTheSameTargetInTwoNoteFoldersIsTwoPictures`).

## File Structure

New production files:

| File | Responsibility |
|---|---|
| `Quoote/ViewModels/NoteAttachments.swift` | `NoteAttachment` model; text parser; server-list mapper; merge and tile helpers |
| `Quoote/Services/AsyncGate.swift` | at most N concurrent holders; cancellation-aware waiters |
| `Quoote/Services/ThumbnailDownsampler.swift` | ImageIO downsample, flatten onto white, JPEG encode |
| `Quoote/Services/ThumbnailDiskCache.swift` | size-capped JPEG folder for Memos pictures |
| `Quoote/Services/MemosAttachmentFetcher.swift` | origin rule, token, thumbnail-then-plain, size cap, redirect guard |
| `Quoote/Services/Vault/VaultFileStore+Attachments.swift` | locate / modification date / thumbnail for vault pictures |
| `Quoote/Services/AttachmentThumbnailLoader.swift` | memory cache, request sharing, gate, failure memory; wires the units together |
| `Quoote/Views/Components/AttachmentTile.swift` | the 56 pt tile and `AttachmentFileIcon` |
| `Quoote/Views/Components/AttachmentBar.swift` | the editor's attachment strip (extracted from `NoteEditorView`) |

Changed production files: `Services/Vault/VaultIndex.swift`, `Services/Vault/VaultStore.swift`, `Services/MemosClient.swift`, `Services/ServerMemosStore.swift`, `ViewModels/UnifiedNote.swift`, `ViewModels/NoteExcerpt.swift`, `Views/Components/NoteRowView.swift`, `Views/NoteEditorView.swift`.

New test files: `NoteAttachmentsTests`, `AsyncGateTests`, `ThumbnailDownsamplerTests`, `ThumbnailDiskCacheTests`, `MemosAttachmentFetcherTests`, `VaultFileStoreAttachmentTests`, `AttachmentThumbnailLoaderTests`, `AttachmentFileIconTests`, `AttachmentTileLayoutTests`, `NoteRowViewLayoutTests`, `AttachmentBarLayoutTests`, `ServerMemosStoreAttachmentsTests`, plus the helpers `TestImages` and `AttachmentStubURLProtocol`. Existing test files extended: `NoteExcerptTests`, `VaultIndexTests`, `VaultStoreTests`, `MemosClientParsingTests`, `UnifiedNoteVaultTests`.

Baseline before this plan: the full suite runs **224 tests, all passing**.

---

### Task 0: Branch, docs and baseline

**Files:**
- Add to git: `docs/superpowers/specs/2026-10-03-attachment-thumbnails-design.md`, `docs/superpowers/plans/2026-10-03-attachment-thumbnails.md`

- [ ] **Step 1: Branch off main**

```bash
git checkout -b feat/attachment-thumbnails
```

Expected: `Switched to a new branch 'feat/attachment-thumbnails'`. `main` stays untouched.

- [ ] **Step 2: Run the whole suite once, before changing anything**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 224 tests, with 0 failures` and `** TEST SUCCEEDED **`. If anything fails here, stop and report it: those failures are not this plan's.

- [ ] **Step 3: Commit the spec and this plan**

```bash
git add docs/superpowers/specs/2026-10-03-attachment-thumbnails-design.md \
        docs/superpowers/plans/2026-10-03-attachment-thumbnails.md
git commit -m "docs: attachment thumbnails spec and implementation plan"
```


---

### Task 1: Attachment model and text parser

The foundation: what an attachment *is*, and how one is found in text or in a server's list. Pure code — no I/O — so the index scan, the row and the editor can all call it freely.

**Files:**
- Create: `Quoote/ViewModels/NoteAttachments.swift`
- Test: `QuooteTests/NoteAttachmentsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct NoteAttachment: Codable, Hashable` — `enum Kind: String, Codable { case image, file }`; `let target: String`; `let name: String`; `let kind: Kind`; `var identity: String`; `var isRemote: Bool`
  - `struct NoteAttachmentTile: Equatable` — `let attachment: NoteAttachment`; `let extra: Int`
  - `enum NoteAttachments` — `static let imageExtensions: Set<String>`; `static func parse(_ text: String) -> [NoteAttachment]`; `static func merged(_ first: [NoteAttachment], _ second: [NoteAttachment]) -> [NoteAttachment]`; `static func tile(from attachments: [NoteAttachment]) -> NoteAttachmentTile?`; `static func removingMemosFileLinks(from text: String) -> String`; `static func fromServerList(memo: [String: Any], fallback: [String: Any]) -> [NoteAttachment]?`; `static func isAbsoluteURL(_:)`, `isMemosRelative(_:)`, `isRemote(_:)` `-> Bool`; `static func urlPath(of target: String) -> String?`; `static func identity(of target: String) -> String`; `static func isMemosFileDestination(_ destination: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `QuooteTests/NoteAttachmentsTests.swift`:

```swift
import XCTest
@testable import Quoote

final class NoteAttachmentsTests: XCTestCase {

    private func image(_ target: String, name: String? = nil) -> NoteAttachment {
        NoteAttachment(target: target, name: name ?? (target as NSString).lastPathComponent, kind: .image)
    }

    private func file(_ target: String, name: String? = nil) -> NoteAttachment {
        NoteAttachment(target: target, name: name ?? (target as NSString).lastPathComponent, kind: .file)
    }

    // MARK: Wikilink embeds

    func testWikilinkImageKeepsItsNameAsWritten() {
        XCTAssertEqual(NoteAttachments.parse("![[photo 1.jpg]]"), [image("photo 1.jpg")])
    }

    func testWikilinkPathKeepsFoldersInTargetAndNamesTheLastComponent() {
        XCTAssertEqual(
            NoteAttachments.parse("![[attachments/trip/a.png]]"),
            [NoteAttachment(target: "attachments/trip/a.png", name: "a.png", kind: .image)]
        )
    }

    func testWikilinkSizeAndPageSuffixesAreNotPartOfTheTarget() {
        XCTAssertEqual(NoteAttachments.parse("![[a.png|200]]"), [image("a.png")])
        XCTAssertEqual(NoteAttachments.parse("![[a.png|200x100]]"), [image("a.png")])
        XCTAssertEqual(NoteAttachments.parse("![[doc.pdf#page=3]]"), [file("doc.pdf")])
    }

    func testWikilinkExtensionsAreMatchedCaseInsensitively() {
        XCTAssertEqual(NoteAttachments.parse("![[IMG_0001.JPG]]"), [image("IMG_0001.JPG")])
        XCTAssertEqual(NoteAttachments.parse("![[Scan.PDF]]"), [file("Scan.PDF")])
    }

    func testWikilinkToANoteOrADottedNoteNameIsNotAnAttachment() {
        XCTAssertEqual(NoteAttachments.parse("![[Some Note]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Some Note#Heading]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Meeting 10.3]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Plan.md]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[Plan.markdown]]"), [])
        XCTAssertEqual(NoteAttachments.parse("![[]]"), [])
    }

    func testWikilinkToOtherFilesIsAFile() {
        XCTAssertEqual(NoteAttachments.parse("![[song.mp3]]"), [file("song.mp3")])
        XCTAssertEqual(NoteAttachments.parse("![[logo.svg]]"), [file("logo.svg")])
    }

    // MARK: Markdown images

    func testMarkdownImageWithAnAbsoluteURLKeepsTheURLAsTarget() {
        let url = "https://memos.example.com/file/attachments/abc/image.jpg"
        XCTAssertEqual(NoteAttachments.parse("![](\(url))"), [image(url, name: "image.jpg")])
    }

    func testMarkdownImageWithARelativePathIsPercentDecoded() {
        XCTAssertEqual(
            NoteAttachments.parse("![](attachments/my%20pic.png)"),
            [NoteAttachment(target: "attachments/my pic.png", name: "my pic.png", kind: .image)]
        )
    }

    func testMarkdownImageInAngleBracketsMayContainSpaces() {
        XCTAssertEqual(NoteAttachments.parse("![alt](<my pic.png>)"), [image("my pic.png")])
    }

    func testMarkdownImageTitleIsNotPartOfTheTarget() {
        XCTAssertEqual(NoteAttachments.parse("![alt](pic.png \"A caption\")"), [image("pic.png")])
    }

    func testMarkdownImageWithANonHTTPSchemeIsIgnored() {
        XCTAssertEqual(NoteAttachments.parse("![](data:image/png;base64,AAAA)"), [])
        XCTAssertEqual(NoteAttachments.parse("![](file:///tmp/a.png)"), [])
        XCTAssertEqual(NoteAttachments.parse("![]()"), [])
    }

    func testMarkdownImageKindFollowsTheExtensionAndDefaultsToImage() {
        XCTAssertEqual(NoteAttachments.parse("![](https://x.test/report.pdf)").map(\.kind), [.file])
        XCTAssertEqual(NoteAttachments.parse("![](https://x.test/photo)").map(\.kind), [.image])
        XCTAssertEqual(NoteAttachments.parse("![](https://x.test/Photo.HEIC)").map(\.kind), [.image])
    }

    func testMarkdownImageNameDropsTheQueryAndIsPercentDecoded() {
        XCTAssertEqual(
            NoteAttachments.parse("![](https://x.test/a/b%20c.png?size=2)").map(\.name),
            ["b c.png"]
        )
    }

    // MARK: Memos file links

    func testLinkToAMemosFileIsAnAttachmentNamedByItsText() {
        let url = "https://memos.example.com/file/attachments/u/Report.pdf"
        XCTAssertEqual(
            NoteAttachments.parse("[Report.pdf](\(url))"),
            [NoteAttachment(target: url, name: "Report.pdf", kind: .file)]
        )
    }

    func testLinkToAMemosImageFileIsAnImage() {
        XCTAssertEqual(
            NoteAttachments.parse("[pic.jpg](/file/attachments/u/pic.jpg)"),
            [NoteAttachment(target: "/file/attachments/u/pic.jpg", name: "pic.jpg", kind: .image)]
        )
    }

    func testLinkToTheOlderMemosFilePathIsAnAttachment() {
        XCTAssertEqual(
            NoteAttachments.parse("[x.pdf](/o/r/12/x.pdf)"),
            [NoteAttachment(target: "/o/r/12/x.pdf", name: "x.pdf", kind: .file)]
        )
    }

    func testLinkWithSpacesInTheFilenameIsKeptWhole() {
        // Quoote writes the uploaded filename raw, so a name with spaces is a destination with spaces.
        let url = "https://m.example.com/file/attachments/u/My Doc.pdf"
        XCTAssertEqual(
            NoteAttachments.parse("[My Doc.pdf](\(url))"),
            [NoteAttachment(target: url, name: "My Doc.pdf", kind: .file)]
        )
    }

    func testEmptyLinkTextFallsBackToTheFilename() {
        XCTAssertEqual(NoteAttachments.parse("[](/file/attachments/u/a.jpg)").map(\.name), ["a.jpg"])
    }

    func testOrdinaryLinksAreNotAttachments() {
        XCTAssertEqual(NoteAttachments.parse("[site](https://example.com/page)"), [])
        XCTAssertEqual(NoteAttachments.parse("[note](folder/note.md)"), [])
        XCTAssertEqual(NoteAttachments.parse("[mail](mailto:a@b.test)"), [])
    }

    func testAnImageWrappedInALinkIsOneImage() {
        let text = "[![](/file/attachments/u/a.jpg)](/file/attachments/u/a.jpg)"
        XCTAssertEqual(NoteAttachments.parse(text), [image("/file/attachments/u/a.jpg")])
    }

    // MARK: Order, duplicates, text

    func testAttachmentsComeInDocumentOrderAcrossSyntaxes() {
        let text = """
        ![[first.png]] some words
        [second.pdf](/file/attachments/u/second.pdf)
        ![](https://m.example.com/file/attachments/u/third.jpg)
        """
        XCTAssertEqual(NoteAttachments.parse(text).map(\.name), ["first.png", "second.pdf", "third.jpg"])
    }

    func testDuplicatesCollapseToTheFirst() {
        XCTAssertEqual(NoteAttachments.parse("![[a.png]] and again ![[a.png]]"), [image("a.png")])
    }

    func testAnAbsoluteAndARelativeLinkToTheSameMemosFileAreOne() {
        let text = "![](https://m.example.com/file/attachments/u/a.jpg)\n[a.jpg](/file/attachments/u/a.jpg)"
        XCTAssertEqual(NoteAttachments.parse(text).count, 1)
    }

    func testEmojiAndNonLatinTextBeforeAnEmbedDoNotShiftIt() {
        let text = "😀 日本語のメモ 👨‍👩‍👧 ![[写真.jpg]] — [r.pdf](/file/attachments/u/r.pdf)"
        XCTAssertEqual(
            NoteAttachments.parse(text),
            [image("写真.jpg"), file("/file/attachments/u/r.pdf", name: "r.pdf")]
        )
    }

    func testTextWithoutBracketsHasNoAttachments() {
        XCTAssertEqual(NoteAttachments.parse(""), [])
        XCTAssertEqual(NoteAttachments.parse("just words, no embeds"), [])
    }

    // MARK: Identity and classification

    func testIdentityIgnoresHostEncodingQueryAndFragment() {
        let a = file("/file/attachments/u/My%20Doc.pdf")
        let b = file("https://m.example.com/file/attachments/u/My Doc.pdf?x=1#top")
        XCTAssertEqual(a.identity, b.identity)
        XCTAssertEqual(file("Docs/a.pdf").identity, "Docs/a.pdf")
    }

    func testRemoteMeansAURLOrAMemosPath() {
        XCTAssertTrue(file("https://x.test/a.png").isRemote)
        XCTAssertTrue(file("HTTP://x.test/a.png").isRemote)
        XCTAssertTrue(file("/file/attachments/u/a.png").isRemote)
        XCTAssertTrue(file("/o/r/1/a.png").isRemote)
        XCTAssertFalse(file("a.png").isRemote)
        XCTAssertFalse(file("/a.png").isRemote)
        XCTAssertFalse(file("attachments/a.png").isRemote)
    }

    // MARK: merged / tile

    func testMergedKeepsTheFirstListFirstAndDropsDuplicates() {
        let text = [image("/file/attachments/u/a.jpg")]
        let server = [image("https://m.example.com/file/attachments/u/a.jpg"), file("/file/attachments/u/b.pdf")]
        XCTAssertEqual(NoteAttachments.merged(text, server).map(\.name), ["a.jpg", "b.pdf"])
    }

    func testTileOfNothingIsNil() {
        XCTAssertNil(NoteAttachments.tile(from: []))
    }

    func testTilePrefersTheFirstImageAndCountsTheRest() {
        let tile = NoteAttachments.tile(from: [file("a.pdf"), image("b.png"), image("c.png")])
        XCTAssertEqual(tile, NoteAttachmentTile(attachment: image("b.png"), extra: 2))
    }

    func testTileOfOnlyFilesIsTheFirstFile() {
        let tile = NoteAttachments.tile(from: [file("a.pdf"), file("b.pdf")])
        XCTAssertEqual(tile, NoteAttachmentTile(attachment: file("a.pdf"), extra: 1))
    }

    func testTileOfASingleAttachmentHasNoExtras() {
        XCTAssertEqual(NoteAttachments.tile(from: [image("a.png")])?.extra, 0)
    }

    // MARK: Excerpt support

    func testRemovingMemosFileLinksKeepsOrdinaryLinks() {
        let text = "see [Report.pdf](https://m.example.com/file/attachments/u/Report.pdf) and [site](https://example.com)"
        XCTAssertEqual(NoteAttachments.removingMemosFileLinks(from: text), "see  and [site](https://example.com)")
    }

    // MARK: Server list

    func testServerListReadsTheModernAttachmentsArray() {
        let memo: [String: Any] = [
            "attachments": [
                ["name": "attachments/abc", "filename": "image.jpg", "type": "image/jpeg"],
                ["name": "attachments/def", "filename": "Report.pdf", "type": "application/pdf"],
            ],
        ]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: memo, fallback: [:]),
            [
                NoteAttachment(target: "/file/attachments/abc/image.jpg", name: "image.jpg", kind: .image),
                NoteAttachment(target: "/file/attachments/def/Report.pdf", name: "Report.pdf", kind: .file),
            ]
        )
    }

    func testServerListReadsOlderResourcesAndNumericIDs() {
        let memo: [String: Any] = [
            "resources": [
                ["name": "resources/7", "filename": "a.png", "type": "image/png"],
                ["id": 12, "filename": "b.png", "type": "image/png"],
                ["id": "13", "filename": "c.pdf", "type": "application/pdf"],
            ],
        ]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: memo, fallback: [:])?.map(\.target),
            ["/file/resources/7/a.png", "/o/r/12/b.png", "/o/r/13/c.pdf"]
        )
    }

    func testServerListSkipsElementsWithoutAFilenameOrAnAddress() {
        let memo: [String: Any] = [
            "attachments": [
                ["name": "attachments/x", "filename": "  "],
                ["name": "attachments/y"],
                ["filename": "orphan.png"],
            ],
        ]
        XCTAssertEqual(NoteAttachments.fromServerList(memo: memo, fallback: [:]), [])
    }

    func testServerListTreatsSVGAndUnknownTypesAsFiles() {
        let memo: [String: Any] = [
            "attachments": [
                ["name": "attachments/a", "filename": "logo.svg", "type": "image/svg+xml"],
                ["name": "attachments/b", "filename": "mystery", "type": ""],
                ["name": "attachments/c", "filename": "Shot.PNG", "type": "IMAGE/PNG"],
            ],
        ]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: memo, fallback: [:])?.map(\.kind),
            [.file, .file, .image]
        )
    }

    func testServerListIsNilWhenTheResponseHasNoListAndEmptyWhenTheListIsEmpty() {
        XCTAssertNil(NoteAttachments.fromServerList(memo: ["content": "hi"], fallback: [:]))
        XCTAssertNil(NoteAttachments.fromServerList(memo: ["attachments": 2], fallback: [:]))
        XCTAssertEqual(NoteAttachments.fromServerList(memo: ["attachments": [[String: Any]]()], fallback: [:]), [])
    }

    func testServerListFallsBackToThePayloadAndTheEnvelope() {
        let element: [String: Any] = ["name": "attachments/a", "filename": "a.png", "type": "image/png"]
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: ["payload": ["attachments": [element]]], fallback: [:])?.count, 1
        )
        XCTAssertEqual(
            NoteAttachments.fromServerList(memo: [:], fallback: ["attachments": [element]])?.count, 1
        )
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/NoteAttachmentsTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'NoteAttachment' in scope` / `cannot find 'NoteAttachments' in scope`.

- [ ] **Step 3: Implement**

Create `Quoote/ViewModels/NoteAttachments.swift`:

```swift
import Foundation

/// A picture or file attached to a note: found in the note's text, in its vault index entry, or on its memo.
struct NoteAttachment: Codable, Hashable {
    enum Kind: String, Codable {
        case image
        case file
    }

    /// Where the bytes live, as written: a vault name or path (`photo 1.jpg`, `attachments/a.png`), an absolute
    /// http(s) URL, or a Memos-relative path (`/file/attachments/{uid}/{filename}`, `/o/r/{id}/{filename}`).
    let target: String
    /// What a file tile and VoiceOver call it.
    let name: String
    let kind: Kind

    /// Two attachments with the same identity are one attachment: the URL path for a URL or Memos-relative target
    /// (so a link in a memo's text and the same file in the server's list collapse), the target otherwise.
    var identity: String { NoteAttachments.identity(of: target) }

    /// True when the bytes come from a URL or a Memos-relative path, false when they are in the vault.
    var isRemote: Bool { NoteAttachments.isRemote(target) }
}

/// What a history row shows for a note's attachments: one tile, and how many more the note holds.
struct NoteAttachmentTile: Equatable {
    let attachment: NoteAttachment
    let extra: Int
}

/// Finds a note's attachments. Pure: no I/O, so it is safe to call from a view body or the index scan.
enum NoteAttachments {

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "avif"
    ]

    // MARK: Text

    /// Every attachment embedded in `text`, in document order, duplicates collapsed to the first.
    ///
    /// Three syntaxes: `![[wikilink]]` embeds, `![alt](target)` images, and `[name](url)` links to Memos files.
    static func parse(_ text: String) -> [NoteAttachment] {
        guard text.contains("[") else { return [] }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        // A match is blanked once claimed, so a link wrapped around an image (`[![](a.jpg)](b)`) isn't read twice.
        let masked = NSMutableString(string: text)
        var found: [(location: Int, attachment: NoteAttachment)] = []

        for match in wikilinkRegex.matches(in: text, range: whole) {
            blank(match.range, in: masked)
            if let attachment = wikilinkAttachment(source.substring(with: match.range(at: 1))) {
                found.append((match.range.location, attachment))
            }
        }
        for match in imageRegex.matches(in: text, range: whole) {
            blank(match.range, in: masked)
            if let attachment = imageAttachment(destination: source.substring(with: match.range(at: 1))) {
                found.append((match.range.location, attachment))
            }
        }
        let rest = masked as String
        let restSource = rest as NSString
        for match in linkRegex.matches(in: rest, range: whole) {
            let label = restSource.substring(with: match.range(at: 1))
            let destination = restSource.substring(with: match.range(at: 2))
            if let attachment = linkAttachment(label: label, destination: destination) {
                found.append((match.range.location, attachment))
            }
        }
        return merged(found.sorted { $0.location < $1.location }.map(\.attachment), [])
    }

    /// `first` then `second`, with later duplicates (by identity) dropped.
    static func merged(_ first: [NoteAttachment], _ second: [NoteAttachment]) -> [NoteAttachment] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0.identity).inserted }
    }

    /// The tile for a history row: the first picture, else the first file, plus how many more there are.
    static func tile(from attachments: [NoteAttachment]) -> NoteAttachmentTile? {
        guard let first = attachments.first else { return nil }
        let shown = attachments.first(where: { $0.kind == .image }) ?? first
        return NoteAttachmentTile(attachment: shown, extra: attachments.count - 1)
    }

    /// `text` without its `[name](url)` links to Memos files — what a history excerpt shows.
    static func removingMemosFileLinks(from text: String) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in linkRegex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed()
        where isMemosFileDestination(source.substring(with: match.range(at: 2))) {
            result.deleteCharacters(in: match.range)
        }
        return result as String
    }

    // MARK: Server list

    /// The attachments a Memos server lists on a memo: `attachments`, or `resources` / `resourceList` on older
    /// servers. `nil` when the response carries no list at all, so a caller keeps what it already knew; `[]` when
    /// it carries a list with nothing usable in it.
    static func fromServerList(memo: [String: Any], fallback: [String: Any]) -> [NoteAttachment]? {
        let sources: [[String: Any]?] = [
            memo, memo["payload"] as? [String: Any], fallback, fallback["payload"] as? [String: Any]
        ]
        var sawList = false
        for key in ["attachments", "resources", "resourceList"] {
            for source in sources {
                guard let list = source?[key] as? [[String: Any]] else { continue }
                sawList = true
                let parsed = list.compactMap(serverAttachment)
                if !parsed.isEmpty { return merged(parsed, []) }
            }
        }
        return sawList ? [] : nil
    }

    private static func serverAttachment(_ element: [String: Any]) -> NoteAttachment? {
        guard let filename = (element["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.isEmpty else { return nil }
        let target: String
        if let name = (element["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            target = "/file/\(name)/\(filename)"
        } else if let id = (element["id"] as? Int) ?? (element["id"] as? String).flatMap({ Int($0) }) {
            target = "/o/r/\(id)/\(filename)"
        } else {
            return nil
        }
        let mime = (element["type"] as? String)?.lowercased() ?? ""
        let isImage = mime.hasPrefix("image/") && mime != "image/svg+xml"
        return NoteAttachment(target: target, name: filename, kind: isImage ? .image : .file)
    }

    // MARK: Targets

    static func isAbsoluteURL(_ target: String) -> Bool {
        target.range(of: "http://", options: [.anchored, .caseInsensitive]) != nil
            || target.range(of: "https://", options: [.anchored, .caseInsensitive]) != nil
    }

    static func isMemosRelative(_ target: String) -> Bool {
        target.hasPrefix("/file/") || target.hasPrefix("/o/r/")
    }

    static func isRemote(_ target: String) -> Bool {
        isAbsoluteURL(target) || isMemosRelative(target)
    }

    /// The path of an absolute URL or a Memos-relative target, percent-decoded, without query or fragment.
    /// `nil` for anything else (a vault name or path).
    static func urlPath(of target: String) -> String? {
        var path: Substring
        if isAbsoluteURL(target) {
            guard let schemeEnd = target.range(of: "://") else { return nil }
            let afterScheme = target[schemeEnd.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return "/" }
            path = afterScheme[slash...]
        } else if isMemosRelative(target) {
            path = target[...]
        } else {
            return nil
        }
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<cut] }
        let raw = String(path)
        return raw.removingPercentEncoding ?? raw
    }

    static func identity(of target: String) -> String {
        urlPath(of: target) ?? target
    }

    /// Whether a link destination points at a file a Memos server hosts (`/file/…` or `/o/r/…`), absolute or relative.
    static func isMemosFileDestination(_ destination: String) -> Bool {
        guard let path = urlPath(of: unwrapped(destination)) else { return false }
        return path.hasPrefix("/file/") || path.hasPrefix("/o/r/")
    }

    // MARK: Syntaxes

    private static let wikilinkRegex = try! NSRegularExpression(pattern: #"!\[\[([^\]]*)\]\]"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]*)\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]]*)\]\(([^)]*)\)"#)

    private static func blank(_ range: NSRange, in text: NSMutableString) {
        text.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
    }

    /// `![[target|size#section]]`. A note transclusion (`![[Some Note]]`, `![[Plan.md]]`) or a dotted note name
    /// (`![[Meeting 10.3]]`) isn't an attachment: it needs an extension of 1–5 letters and digits, with a letter.
    private static func wikilinkAttachment(_ inner: String) -> NoteAttachment? {
        let end = inner.firstIndex(where: { $0 == "|" || $0 == "#" }) ?? inner.endIndex
        let target = inner[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let name = lastComponent(of: target)
        guard let ext = fileExtension(of: name),
              ext.contains(where: \.isLetter),
              ext != "md", ext != "markdown" else { return nil }
        return NoteAttachment(target: target, name: name, kind: imageExtensions.contains(ext) ? .image : .file)
    }

    /// `![alt](destination)`. Written as an image, so it is one unless its extension says otherwise.
    private static func imageAttachment(destination raw: String) -> NoteAttachment? {
        let destination = firstDestination(of: raw)
        guard !destination.isEmpty else { return nil }
        // `data:`, `file:` and friends are not something to fetch or look up.
        if hasScheme(destination) && !isAbsoluteURL(destination) { return nil }
        let target = isRemote(destination) ? destination : (destination.removingPercentEncoding ?? destination)
        let name = lastComponent(of: urlPath(of: destination) ?? target)
        let ext = fileExtension(of: name)
        let isFile = ext.map { !imageExtensions.contains($0) } ?? false
        return NoteAttachment(target: target, name: name, kind: isFile ? .file : .image)
    }

    /// `[name](url)` where the url is a Memos file (how Quoote links a file it uploaded).
    private static func linkAttachment(label: String, destination raw: String) -> NoteAttachment? {
        let destination = unwrapped(raw)
        guard isMemosFileDestination(destination) else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedLabel.isEmpty ? lastComponent(of: urlPath(of: destination) ?? destination) : trimmedLabel
        let isImage = fileExtension(of: name).map { imageExtensions.contains($0) } ?? false
        return NoteAttachment(target: destination, name: name, kind: isImage ? .image : .file)
    }

    // MARK: Helpers

    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// The lowercased extension, when the name ends in a dot and 1–5 ASCII letters or digits.
    private static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard (1...5).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return ext.lowercased()
    }

    /// A link destination whole: trimmed, and without `<…>` if it was wrapped.
    private static func unwrapped(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return trimmed
    }

    /// An image destination: inside `<…>`, else up to the first whitespace (what follows is a title).
    private static func firstDestination(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { return unwrapped(trimmed) }
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    private static func hasScheme(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":"), colon != destination.startIndex else { return false }
        let scheme = destination[..<colon]
        guard scheme.first?.isLetter == true else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/NoteAttachmentsTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 39 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/ViewModels/NoteAttachments.swift QuooteTests/NoteAttachmentsTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: find a note's attachments in its text and in a Memos server's list"
```

---

### Task 2: History excerpts drop Memos file links

A row that shows `[Report.pdf](https://…/file/attachments/…)` as raw text would repeat what the tile already says. `NoteExcerpt` already drops `![[…]]` and `![](…)`; it now drops links to Memos files too, and leaves ordinary links alone.

**Files:**
- Modify: `Quoote/ViewModels/NoteExcerpt.swift`
- Test: `QuooteTests/NoteExcerptTests.swift`

**Interfaces:**
- Consumes: `NoteAttachments.removingMemosFileLinks(from:)` (Task 1).
- Produces: `NoteExcerpt.make(from:)` no longer contains `[name](url)` links whose path starts `/file/` or `/o/r/`.

- [ ] **Step 1: Write the failing tests**

In `QuooteTests/NoteExcerptTests.swift`, replace:

```swift
    func testUnifiedLocalNoteUsesExcerpt() {
        let note = UnifiedNote.local(Draft(text: "# Title\nbody #tag"))
        XCTAssertEqual(note.excerpt, "Title body #tag")
    }
}
```

with:

```swift
    func testUnifiedLocalNoteUsesExcerpt() {
        let note = UnifiedNote.local(Draft(text: "# Title\nbody #tag"))
        XCTAssertEqual(note.excerpt, "Title body #tag")
    }

    func testDropsLinksToMemosFilesButKeepsOrdinaryLinks() {
        let text = """
        Quarterly numbers
        [Report.pdf](https://m.example.com/file/attachments/u/Report.pdf)
        see [the site](https://example.com) too
        """
        XCTAssertEqual(NoteExcerpt.make(from: text), "Quarterly numbers see [the site](https://example.com) too")
    }

    func testANoteThatIsOnlyAFileLinkHasNoExcerpt() {
        let link = "[My Doc.pdf](https://m.example.com/file/attachments/u/My Doc.pdf)"
        XCTAssertEqual(NoteExcerpt.make(from: link), "")
    }

    func testDropsTheOlderMemosFilePathToo() {
        XCTAssertEqual(NoteExcerpt.make(from: "Scan [x.pdf](/o/r/12/x.pdf)"), "Scan")
    }
}
```


- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/NoteExcerptTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: 3 failures — `testDropsLinksToMemosFilesButKeepsOrdinaryLinks`, `testANoteThatIsOnlyAFileLinkHasNoExcerpt`, `testDropsTheOlderMemosFilePathToo` (the link text is still in the excerpt) — and `** TEST FAILED **`.

- [ ] **Step 3: Implement**

In `Quoote/ViewModels/NoteExcerpt.swift`, replace:

```swift
            line = replacing(embedRegex, in: line)
```

with:

```swift
            line = replacing(embedRegex, in: line)
            line = NoteAttachments.removingMemosFileLinks(from: line)
```


- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/NoteExcerptTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 8 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/ViewModels/NoteExcerpt.swift QuooteTests/NoteExcerptTests.swift
git commit -m "feat: history excerpts drop links to Memos files"
```


---

### Task 3: The vault index carries each note's attachments

A history row can't read its note (that would force an iCloud download per row), so the index records what each note embeds. `nil` means "not scanned": an index saved before this field existed is re-read once, in the background, while its rows keep rendering from the old data — no blank list, no index-version bump.

**Known effect to tell the user about:** the first refresh after this ships reads every note once. For a note iCloud has evicted, "read" means the existing placeholder path in `performRefresh` asks iCloud to download it (as the very first index build already does); the notes are small `.md` files, and attachments are not touched. After that one pass the cheap modification-date diff applies again.

**Files:**
- Modify: `Quoote/Services/Vault/VaultIndex.swift`
- Modify: `Quoote/Services/Vault/VaultStore.swift` (placeholder entries keep the prior list)
- Test: `QuooteTests/VaultIndexTests.swift`, `QuooteTests/VaultStoreTests.swift`

**Interfaces:**
- Consumes: `NoteAttachments.parse(_:)`, `NoteAttachment` (Task 1).
- Produces: `VaultIndexEntry.attachments: [NoteAttachment]?` and the initializer parameter `attachments: [NoteAttachment]? = nil` (after `needsContent`); `VaultIndexEntry.make(from:)` fills it (never `nil`); `VaultIndex.diff` sends an entry with `attachments == nil` to `needsRead`.

- [ ] **Step 1: Write the failing tests**

The existing `entry` helper builds an already-scanned entry, so it must now say `attachments: []` — without that every existing diff test would see an unscanned entry.

In `QuooteTests/VaultIndexTests.swift`, replace:

```swift
    private func entry(_ path: String, modified: TimeInterval, size: Int) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: path,
            title: "Title",
            preview: "Preview",
            tags: [],
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: size
        )
    }
```

with:

```swift
    private func entry(_ path: String, modified: TimeInterval, size: Int) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: path,
            title: "Title",
            preview: "Preview",
            tags: [],
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: size,
            attachments: []
        )
    }
```


In `QuooteTests/VaultIndexTests.swift`, replace:

```swift
        XCTAssertEqual(decoded.relativePath, "a.md")
        XCTAssertNil(decoded.needsContent)
    }
}
```

with:

```swift
        XCTAssertEqual(decoded.relativePath, "a.md")
        XCTAssertNil(decoded.needsContent)
    }

    func testEntryFromNoteListsTheAttachmentsInItsBody() {
        let note = VaultNote(
            relativePath: "a.md",
            frontmatter: nil,
            body: "Trip\n![[beach.jpg]]\n![[notes.pdf]]\n[[Another Note]]\n",
            modifiedAt: Date(timeIntervalSince1970: 100),
            fileSize: 42
        )
        let made = VaultIndexEntry.make(from: note)
        XCTAssertEqual(made.attachments?.map(\.name), ["beach.jpg", "notes.pdf"])
        XCTAssertEqual(made.attachments?.map(\.kind), [.image, .file])
    }

    func testEntryFromNoteWithNoAttachmentsRecordsThatItWasScanned() {
        let note = VaultNote(
            relativePath: "a.md", frontmatter: nil, body: "Just words\n",
            modifiedAt: Date(timeIntervalSince1970: 100), fileSize: 11
        )
        XCTAssertEqual(VaultIndexEntry.make(from: note).attachments, [])
    }

    /// An index persisted before attachments were recorded has `nil` for every entry. Each is read once more,
    /// whatever its modification date and size say; afterwards the usual cheap diff applies.
    func testEntryNeverScannedForAttachmentsIsReadAgain() {
        let unscanned = VaultIndexEntry(
            relativePath: "a.md", title: "T", preview: "P", tags: [],
            modifiedAt: Date(timeIntervalSince1970: 100), fileSize: 10
        )
        XCTAssertNil(unscanned.attachments)

        let diff = VaultIndex.diff(index: [unscanned], disk: [metadata("a.md", modified: 100, size: 10)])

        XCTAssertEqual(diff.needsRead, ["a.md"])
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    func testEntryScannedWithNoAttachmentsIsNotReadAgain() {
        let diff = VaultIndex.diff(
            index: [entry("a.md", modified: 100, size: 10)],
            disk: [metadata("a.md", modified: 100, size: 10)]
        )
        XCTAssertTrue(diff.needsRead.isEmpty)
        XCTAssertEqual(diff.unchanged.map(\.relativePath), ["a.md"])
    }

    func testVaultIndexEntryDecodesOldJSONWithoutAttachments() throws {
        let oldJSON = """
        {"relativePath":"a.md","title":"A","preview":"P","tags":[],"modifiedAt":719000000,"fileSize":10}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VaultIndexEntry.self, from: oldJSON)
        XCTAssertNil(decoded.attachments)
    }

    func testAttachmentsSurviveASaveAndLoad() {
        let entries = [VaultIndexEntry(
            relativePath: "a.md", title: "T", preview: "P", tags: [],
            modifiedAt: Date(timeIntervalSince1970: 100), fileSize: 10,
            attachments: [NoteAttachment(target: "a.png", name: "a.png", kind: .image)]
        )]
        VaultIndex.save(entries)
        XCTAssertEqual(VaultIndex.load(), entries)
    }
}
```


In `QuooteTests/VaultStoreTests.swift`, replace:

```swift
    /// Minor 5: a genuine permission failure while writing must surface as
```

with:

```swift
    /// A note indexed before attachments were recorded has `attachments == nil` and is read once more, so its
    /// row can show a tile — whatever its modification date and size say.
    func testRefreshBackfillsAttachmentsForANoteIndexedBeforeTheFieldExisted() async throws {
        try "Look at this\n![[trip.jpg]]\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let onDisk = try XCTUnwrap(try VaultFileStore(root: root).listMarkdownFiles().first)
        VaultIndex.save([VaultIndexEntry(
            relativePath: "a.md", title: "Look at this", preview: "Look at this", tags: [],
            modifiedAt: onDisk.modifiedAt, fileSize: onDisk.fileSize, attachments: nil
        )])

        await store.refresh()

        XCTAssertEqual(store.entries.first?.attachments?.map(\.name), ["trip.jpg"])
    }

    /// Once scanned, a note whose file hasn't changed is left alone: the backfill is a one-time cost.
    func testRefreshDoesNotReReadANoteThatWasAlreadyScanned() async throws {
        try "Look\n![[trip.jpg]]\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let onDisk = try XCTUnwrap(try VaultFileStore(root: root).listMarkdownFiles().first)
        VaultIndex.save([VaultIndexEntry(
            relativePath: "a.md", title: "Look", preview: "Look", tags: [],
            modifiedAt: onDisk.modifiedAt, fileSize: onDisk.fileSize, attachments: []
        )])

        await store.refresh()

        XCTAssertEqual(store.entries.first?.attachments, [], "same date, same size, already scanned: not read again")
    }

    /// The placeholder for an evicted iCloud note keeps what the index already knew, so its row keeps its tile.
    func testAnEvictedNotesPlaceholderKeepsItsPriorAttachments() async throws {
        let prior = [NoteAttachment(target: "trip.jpg", name: "trip.jpg", kind: .image)]
        VaultIndex.save([VaultIndexEntry(
            relativePath: "Foo.md", title: "Foo", preview: "Foo", tags: [],
            modifiedAt: Date(timeIntervalSince1970: 100), fileSize: 10, attachments: prior
        )])
        try "placeholder"
            .write(to: root.appendingPathComponent(".Foo.md.icloud"), atomically: true, encoding: .utf8)

        await store.refresh()

        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.needsContent, true)
        XCTAssertEqual(entry.attachments, prior)
    }

    /// Minor 5: a genuine permission failure while writing must surface as
```


- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/VaultIndexTests -only-testing:QuooteTests/VaultStoreTests \
  2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `extra argument 'attachments' in call` and `value of type 'VaultIndexEntry' has no member 'attachments'`.

- [ ] **Step 3: Implement**

In `VaultIndex.swift`, the property, the initializer, `make(from:)` and the diff rule:

In `Quoote/Services/Vault/VaultIndex.swift`, replace:

```swift
    let needsContent: Bool?

    var id: String { relativePath }
```

with:

```swift
    let needsContent: Bool?
    /// The pictures and files the note's body embeds (`NoteAttachments.parse`), for its row's tile. `nil` means
    /// "not scanned": an index persisted before this field existed. `VaultIndex.diff` re-reads such an entry
    /// once, in the background, while its row keeps rendering from the old data. `[]` means scanned, none found.
    /// Optional (not defaulted) so that old index still decodes, as with `needsContent`.
    let attachments: [NoteAttachment]?

    var id: String { relativePath }
```


In `Quoote/Services/Vault/VaultIndex.swift`, replace:

```swift
        fileSize: Int,
        needsContent: Bool? = nil
    ) {
```

with:

```swift
        fileSize: Int,
        needsContent: Bool? = nil,
        attachments: [NoteAttachment]? = nil
    ) {
```


In `Quoote/Services/Vault/VaultIndex.swift`, replace:

```swift
        self.needsContent = needsContent
    }
```

with:

```swift
        self.needsContent = needsContent
        self.attachments = attachments
    }
```


In `Quoote/Services/Vault/VaultIndex.swift`, replace:

```swift
            modifiedAt: note.modifiedAt,
            fileSize: note.fileSize
        )
```

with:

```swift
            modifiedAt: note.modifiedAt,
            fileSize: note.fileSize,
            attachments: NoteAttachments.parse(note.body)
        )
```


In `Quoote/Services/Vault/VaultIndex.swift`, replace:

```swift
            if existing.needsContent == true {
                needsRead.append(file.relativePath)
                continue
            }
```

with:

```swift
            if existing.needsContent == true {
                needsRead.append(file.relativePath)
                continue
            }
            // An entry from before attachments were indexed is read once more, whatever its mtime and size say.
            if existing.attachments == nil {
                needsRead.append(file.relativePath)
                continue
            }
```


In `VaultStore.swift`, the placeholder for an evicted note keeps the prior entry's list (it stays `nil` for a note never seen, until its file downloads):

In `Quoote/Services/Vault/VaultStore.swift`, replace:

```swift
                                fileSize: prior.fileSize,
                                needsContent: true
                            ))
```

with:

```swift
                                fileSize: prior.fileSize,
                                needsContent: true,
                                attachments: prior.attachments
                            ))
```


- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/VaultIndexTests -only-testing:QuooteTests/VaultStoreTests \
  2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 48 tests, with 0 failures` (17 + 31) and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/Vault/VaultIndex.swift Quoote/Services/Vault/VaultStore.swift \
        QuooteTests/VaultIndexTests.swift QuooteTests/VaultStoreTests.swift
git commit -m "feat: index each vault note's attachments; re-read unscanned entries once"
```


---

### Task 4: Memos summaries carry the server's attachment list

A picture added in the Memos web app is held on the memo, not linked in its text, so it has to come from the server's `attachments` list (`resources` / `resourceList` on older servers). `nil` means the response carried no list, so a merge keeps what the app already knew; `[]` is the server saying "none".

**Files:**
- Modify: `Quoote/Services/MemosClient.swift`
- Modify: `Quoote/Services/ServerMemosStore.swift`
- Test: `QuooteTests/MemosClientParsingTests.swift`
- Create test: `QuooteTests/ServerMemosStoreAttachmentsTests.swift`

**Interfaces:**
- Consumes: `NoteAttachments.fromServerList(memo:fallback:)`, `NoteAttachment` (Task 1).
- Produces: `ServerMemoSummary.attachments: [NoteAttachment]?` and the initializer parameter `attachments: [NoteAttachment]? = nil` (after `hasFullContent`); `MemosClient` fills it for every memo it parses; `ServerMemosStore.mergeMemo` keeps `incoming.attachments ?? existing.attachments`.

- [ ] **Step 1: Write the failing tests**

In `QuooteTests/MemosClientParsingTests.swift`, replace:

```swift
    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> MemosClient {
```

with:

```swift
    func testFetchMemosPageMapsTheServersAttachmentListToAttachments() async throws {
        let client = makeClient { _ in
            let body = """
            {
              "memos": [
                {
                  "name": "memos/trip",
                  "content": "Trip",
                  "attachments": [
                    { "name": "attachments/abc", "filename": "image.jpg", "type": "image/jpeg" },
                    { "name": "attachments/def", "filename": "Report.pdf", "type": "application/pdf" }
                  ]
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com/api/v1/memos")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let page = try await client.fetchMemosPage(
            baseURLString: "https://example.com", token: "token", allowInsecureHTTP: false, pageSize: 30, pageToken: nil
        )

        let memo = try XCTUnwrap(page.memos.first)
        XCTAssertEqual(memo.attachmentCount, 2)
        XCTAssertEqual(memo.attachments, [
            NoteAttachment(target: "/file/attachments/abc/image.jpg", name: "image.jpg", kind: .image),
            NoteAttachment(target: "/file/attachments/def/Report.pdf", name: "Report.pdf", kind: .file),
        ])
    }

    func testFetchMemosPageReadsAnOlderServersResourcesByNumericID() async throws {
        let client = makeClient { _ in
            let body = """
            {
              "memos": [
                {
                  "name": "memos/old",
                  "content": "Old server",
                  "resources": [ { "id": 12, "filename": "b.png", "type": "image/png" } ]
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com/api/v1/memos")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let page = try await client.fetchMemosPage(
            baseURLString: "https://example.com", token: "token", allowInsecureHTTP: false, pageSize: 30, pageToken: nil
        )

        XCTAssertEqual(page.memos.first?.attachments, [
            NoteAttachment(target: "/o/r/12/b.png", name: "b.png", kind: .image),
        ])
    }

    func testAMemoWithoutAListHasNilAttachmentsAndAnEmptyListIsEmpty() async throws {
        let client = makeClient { _ in
            let body = """
            {
              "memos": [
                { "name": "memos/silent", "content": "No list in this reply" },
                { "name": "memos/none", "content": "Server says none", "attachments": [] }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com/api/v1/memos")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let page = try await client.fetchMemosPage(
            baseURLString: "https://example.com", token: "token", allowInsecureHTTP: false, pageSize: 30, pageToken: nil
        )

        let byID = Dictionary(uniqueKeysWithValues: page.memos.map { ($0.id, $0) })
        XCTAssertNil(byID["memos/silent"]?.attachments)
        XCTAssertEqual(byID["memos/none"]?.attachments, [])
    }

    func testServerMemoSummaryRoundTripsItsAttachmentsAndAnOldCacheStillDecodes() throws {
        let memo = ServerMemoSummary(
            id: "memos/a", resourceName: "memos/a", content: "Hi", updatedAt: nil,
            attachments: [NoteAttachment(target: "/file/attachments/u/a.jpg", name: "a.jpg", kind: .image)]
        )
        let data = try JSONEncoder().encode([memo])
        XCTAssertEqual(try JSONDecoder().decode([ServerMemoSummary].self, from: data), [memo])

        // memo_cache_v1.json written before the field existed.
        let legacy = """
        [{"id":"memos/a","resourceName":"memos/a","content":"Hi","attachmentCount":1,"hasFullContent":true}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([ServerMemoSummary].self, from: legacy)
        XCTAssertNil(decoded.first?.attachments)
        XCTAssertEqual(decoded.first?.attachmentCount, 1)
    }

    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> MemosClient {
```


Create `QuooteTests/ServerMemosStoreAttachmentsTests.swift` (a store merge is tested through `upsertMemo`, which uses `mergeMemo`):

```swift
import XCTest
@testable import Quoote

@MainActor
final class ServerMemosStoreAttachmentsTests: XCTestCase {

    private let photo = NoteAttachment(target: "/file/attachments/u/a.jpg", name: "a.jpg", kind: .image)
    private let report = NoteAttachment(target: "/file/attachments/u/r.pdf", name: "r.pdf", kind: .file)

    private func memo(attachments: [NoteAttachment]?) -> ServerMemoSummary {
        ServerMemoSummary(
            id: "memos/a", resourceName: "memos/a", content: "Trip",
            updatedAt: Date(timeIntervalSince1970: 100), attachments: attachments
        )
    }

    func testAnUpdateWithoutAListKeepsTheOneWeHad() {
        let store = ServerMemosStore()
        store.upsertMemo(memo(attachments: [photo]))

        store.upsertMemo(memo(attachments: nil))

        XCTAssertEqual(store.memo(memoID: "memos/a")?.attachments, [photo])
    }

    func testAnUpdateWithAListReplacesIt() {
        let store = ServerMemosStore()
        store.upsertMemo(memo(attachments: [photo]))

        store.upsertMemo(memo(attachments: [report]))
        XCTAssertEqual(store.memo(memoID: "memos/a")?.attachments, [report])

        store.upsertMemo(memo(attachments: []))
        XCTAssertEqual(store.memo(memoID: "memos/a")?.attachments, [], "the server says none: none")
    }

    func testAMemoSeenForTheFirstTimeKeepsWhatItCameWith() {
        let store = ServerMemosStore()
        store.upsertMemo(memo(attachments: [photo]))
        XCTAssertEqual(store.memo(memoID: "memos/a")?.attachments, [photo])
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/MemosClientParsingTests -only-testing:QuooteTests/ServerMemosStoreAttachmentsTests \
  2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `extra argument 'attachments' in call` / `value of type 'ServerMemoSummary' has no member 'attachments'`.

- [ ] **Step 3: Implement**

In `MemosClient.swift`, the property, the initializer, and the place a memo is parsed:

In `Quoote/Services/MemosClient.swift`, replace:

```swift
    let attachmentCount: Int
    let hasFullContent: Bool

    init(
```

with:

```swift
    let attachmentCount: Int
    let hasFullContent: Bool
    /// What the server lists on the memo, mapped to attachments. A picture added in the Memos web app is only
    /// here, not in `content`. `nil` when the response carried no list (a cache from before this field, an
    /// older server), so a merge keeps what it already knows; `[]` is the server saying "none".
    let attachments: [NoteAttachment]?

    init(
```


In `Quoote/Services/MemosClient.swift`, replace:

```swift
        attachmentCount: Int = 0,
        hasFullContent: Bool? = nil
    ) {
```

with:

```swift
        attachmentCount: Int = 0,
        hasFullContent: Bool? = nil,
        attachments: [NoteAttachment]? = nil
    ) {
```


In `Quoote/Services/MemosClient.swift`, replace:

```swift
        self.attachmentCount = max(0, attachmentCount)
```

with:

```swift
        self.attachmentCount = max(0, attachmentCount)
        self.attachments = attachments
```


In `Quoote/Services/MemosClient.swift`, replace:

```swift
        return ServerMemoSummary(
            id: identifier.id,
            resourceName: identifier.resourceName,
            content: content,
            updatedAt: updatedAt,
            snippet: snippet,
            attachmentCount: attachmentCount,
            hasFullContent: hasFullContent
        )
```

with:

```swift
        return ServerMemoSummary(
            id: identifier.id,
            resourceName: identifier.resourceName,
            content: content,
            updatedAt: updatedAt,
            snippet: snippet,
            attachmentCount: attachmentCount,
            hasFullContent: hasFullContent,
            attachments: NoteAttachments.fromServerList(memo: memo, fallback: memoEnvelope)
        )
```


In `ServerMemosStore.swift`, a merge keeps the incoming list when it has one, else the existing one:

In `Quoote/Services/ServerMemosStore.swift`, replace:

```swift
            snippet: mergedSnippet,
            attachmentCount: mergedAttachmentCount,
            hasFullContent: mergedHasFullContent
        )
```

with:

```swift
            snippet: mergedSnippet,
            attachmentCount: mergedAttachmentCount,
            hasFullContent: mergedHasFullContent,
            attachments: incoming.attachments ?? existing.attachments
        )
```


- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/MemosClientParsingTests -only-testing:QuooteTests/ServerMemosStoreAttachmentsTests \
  2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 11 tests, with 0 failures` (8 + 3) and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/MemosClient.swift Quoote/Services/ServerMemosStore.swift \
        QuooteTests/MemosClientParsingTests.swift QuooteTests/ServerMemosStoreAttachmentsTests.swift \
        Quoote.xcodeproj/project.pbxproj
git commit -m "feat: Memos summaries carry the server's attachment list"
```


---

### Task 5: `UnifiedNote` exposes a note's attachments

One note-level answer to "what is attached?" for all three sources, plus the excerpt rules for a note that is only attachments.

**Files:**
- Modify: `Quoote/ViewModels/UnifiedNote.swift`
- Test: `QuooteTests/UnifiedNoteVaultTests.swift`

**Interfaces:**
- Consumes: `NoteAttachments.parse/merged/tile` (Task 1), `VaultIndexEntry.attachments` (Task 3), `ServerMemoSummary.attachments` (Task 4).
- Produces: `UnifiedNote.attachments: [NoteAttachment]` (`.vault` → the index entry's list or `[]`; `.local` → parsed from the draft text; `.server` → text first, then the server's list, deduplicated); `UnifiedNote.vaultPath: String?`; `UnifiedNote.excerpt` shows no raw title for an attachment-only vault note and the file's name for a file-only note. Replaces the unused `hasAttachments`, `hasImages`, `hasFiles`.

- [ ] **Step 1: Write the failing tests**

The helper gains a `preview` and an `attachments` parameter (defaults keep every existing call as it was):

In `QuooteTests/UnifiedNoteVaultTests.swift`, replace:

```swift
    private func entry(_ path: String, title: String, modified: TimeInterval, tags: [String] = []) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: path,
            title: title,
            preview: "preview",
            tags: tags,
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: 10
        )
    }
```

with:

```swift
    private func entry(
        _ path: String,
        title: String,
        modified: TimeInterval,
        tags: [String] = [],
        preview: String = "preview",
        attachments: [NoteAttachment]? = nil
    ) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: path,
            title: title,
            preview: preview,
            tags: tags,
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: 10,
            attachments: attachments
        )
    }

    private let photo = NoteAttachment(target: "trip.jpg", name: "trip.jpg", kind: .image)
    private let report = NoteAttachment(target: "Report.pdf", name: "Report.pdf", kind: .file)
```


In `QuooteTests/UnifiedNoteVaultTests.swift`, replace:

```swift
    func testMergeExcludesSendingMemosDraft() {
        let sending = Draft(text: "Sending to Memos")
        sending.sendState = .sending
        let notes = UnifiedNote.merge(vaultEntries: [], drafts: [sending])
        XCTAssertTrue(notes.isEmpty)
    }
}
```

with:

```swift
    func testMergeExcludesSendingMemosDraft() {
        let sending = Draft(text: "Sending to Memos")
        sending.sendState = .sending
        let notes = UnifiedNote.merge(vaultEntries: [], drafts: [sending])
        XCTAssertTrue(notes.isEmpty)
    }

    // MARK: Attachments

    /// An image-only note's index preview is empty and its title is the raw `![[trip.jpg]]` line. The row shows
    /// the tile alone, not that markup.
    func testAnImageOnlyVaultNoteShowsNoRawTitle() {
        let note = UnifiedNote.vault(entry("a.md", title: "![[trip.jpg]]", modified: 1, preview: "", attachments: [photo]))
        XCTAssertEqual(note.excerpt, "")
    }

    func testAVaultNoteWithNothingAttachedStillFallsBackToItsTitle() {
        let scanned = UnifiedNote.vault(entry("a.md", title: "Hello", modified: 1, preview: "", attachments: []))
        let unscanned = UnifiedNote.vault(entry("a.md", title: "Hello", modified: 1, preview: "", attachments: nil))
        XCTAssertEqual(scanned.excerpt, "Hello")
        XCTAssertEqual(unscanned.excerpt, "Hello")
    }

    func testAFileOnlyVaultNoteShowsTheFileName() {
        let note = UnifiedNote.vault(entry("a.md", title: "![[Report.pdf]]", modified: 1, preview: "", attachments: [report]))
        XCTAssertEqual(note.excerpt, "Report.pdf")
    }

    func testANoteWithTextKeepsItsTextWhateverItHolds() {
        let note = UnifiedNote.vault(
            entry("a.md", title: "Trip", modified: 1, preview: "Trip notes", attachments: [photo, report])
        )
        XCTAssertEqual(note.excerpt, "Trip notes")
    }

    func testAVaultNoteReadsItsAttachmentsFromTheIndexAndKnowsItsPath() {
        let note = UnifiedNote.vault(entry("folder/a.md", title: "Trip", modified: 1, attachments: [photo]))
        XCTAssertEqual(note.attachments, [photo])
        XCTAssertEqual(note.vaultPath, "folder/a.md")
        XCTAssertEqual(UnifiedNote.vault(entry("b.md", title: "B", modified: 1, attachments: nil)).attachments, [])
    }

    func testALocalDraftFindsItsAttachmentsInItsText() {
        let note = UnifiedNote.local(Draft(text: "Beach day ![[beach.jpg]]"))
        XCTAssertEqual(note.attachments.map(\.name), ["beach.jpg"])
        XCTAssertNil(note.vaultPath)
    }

    func testAFileOnlyLocalDraftShowsTheFileNameAsItsExcerpt() {
        let note = UnifiedNote.local(Draft(text: "[Report.pdf](https://m.example.com/file/attachments/u/Report.pdf)"))
        XCTAssertEqual(note.excerpt, "Report.pdf")
    }

    func testAServerNoteMergesTheTextAndTheServersList() {
        let memo = ServerMemoSummary(
            id: "memos/a", resourceName: "memos/a",
            content: "Trip\n![](https://m.example.com/file/attachments/u/a.jpg)",
            updatedAt: Date(timeIntervalSince1970: 1),
            attachments: [
                NoteAttachment(target: "/file/attachments/u/a.jpg", name: "a.jpg", kind: .image),   // the same picture
                NoteAttachment(target: "/file/attachments/u/b.pdf", name: "b.pdf", kind: .file),
            ]
        )
        let note = UnifiedNote.server(memo, editDraft: nil)
        XCTAssertEqual(note.attachments.map(\.name), ["a.jpg", "b.pdf"])
    }

    func testAServerNoteWithoutAServerListUsesItsText() {
        let memo = ServerMemoSummary(
            id: "memos/a", resourceName: "memos/a",
            content: "Trip ![](https://m.example.com/file/attachments/u/a.jpg)",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(UnifiedNote.server(memo, editDraft: nil).attachments.map(\.name), ["a.jpg"])
    }

    func testAFileOnlyServerNoteShowsTheFileName() {
        let memo = ServerMemoSummary(
            id: "memos/a", resourceName: "memos/a",
            content: "[Report.pdf](/file/attachments/u/Report.pdf)",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(UnifiedNote.server(memo, editDraft: nil).excerpt, "Report.pdf")
    }
}
```


- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/UnifiedNoteVaultTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `value of type 'UnifiedNote' has no member 'attachments'` / `'vaultPath'`.

- [ ] **Step 3: Implement**

In `Quoote/ViewModels/UnifiedNote.swift`, replace:

```swift
    /// The note flattened for a history row. A vault note's content is already the
    /// index's flattened excerpt.
    var excerpt: String {
        if case .vault = self { return content }
        return NoteExcerpt.make(from: content)
    }
```

with:

```swift
    /// The note flattened for a history row. A vault note's content is already the
    /// index's flattened excerpt.
    ///
    /// A note that is only attachments has no text. An image-only vault note shows its tile alone rather
    /// than the raw `![[x.jpg]]` its title falls back to; a note holding just a file shows the file's name.
    var excerpt: String {
        let text: String
        switch self {
        case .vault(let entry):
            let holdsAttachments = !(entry.attachments ?? []).isEmpty
            text = entry.preview.isEmpty && holdsAttachments ? "" : content
        case .local, .server:
            text = NoteExcerpt.make(from: content)
        }
        guard text.isEmpty,
              let tile = NoteAttachments.tile(from: attachments),
              tile.attachment.kind == .file else { return text }
        return tile.attachment.name
    }
```


In `Quoote/ViewModels/UnifiedNote.swift`, replace:

```swift
    var hasAttachments: Bool {
        switch self {
        case .local(let draft): return draft.text.contains("![")
        case .server(let memo, _): return memo.hasAttachments || memo.content.contains("![")
        case .vault: return false
        }
    }

    var hasImages: Bool {
        content.contains("![")
    }

    var hasFiles: Bool {
        switch self {
        case .local, .vault: return false
        case .server(let memo, _): return memo.attachmentCount > 0
        }
    }
```

with:

```swift
    /// What the note holds, for its row's tile: embedded in its text, plus — for a Memos note — what the
    /// server lists on the memo itself (text first, duplicates dropped). A vault row has no body to read, so
    /// it takes the list from its index entry.
    var attachments: [NoteAttachment] {
        switch self {
        case .local(let draft):
            return NoteAttachments.parse(draft.text)
        case .server(let memo, _):
            return NoteAttachments.merged(NoteAttachments.parse(content), memo.attachments ?? [])
        case .vault(let entry):
            return entry.attachments ?? []
        }
    }

    /// The vault-relative path of the note, so `![[picture.png]]` can be found beside it. `nil` unless it is a vault note.
    var vaultPath: String? {
        if case .vault(let entry) = self { return entry.relativePath }
        return nil
    }
```


- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/UnifiedNoteVaultTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 18 tests, with 0 failures` (8 + 10) and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/ViewModels/UnifiedNote.swift QuooteTests/UnifiedNoteVaultTests.swift
git commit -m "feat: UnifiedNote exposes its attachments; attachment-only rows drop the raw title"
```


---

### Task 6: `AsyncGate` — at most N at a time

The loader must run at most 4 loads at once, and a load that is only waiting its turn must be able to drop out when its row scrolls away. This is that primitive, on its own.

**Files:**
- Create: `Quoote/Services/AsyncGate.swift`
- Test: `QuooteTests/AsyncGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `actor AsyncGate` — `init(limit: Int)`; `func acquire() async throws` (throws `CancellationError` if the task is cancelled while waiting; every `acquire()` that returns must be paired with one `release()`); `func release()`. Waiters are admitted in arrival order.

- [ ] **Step 1: Write the failing tests**

Create `QuooteTests/AsyncGateTests.swift`:

```swift
import XCTest
@testable import Quoote

final class AsyncGateTests: XCTestCase {

    private actor Probe {
        private(set) var active = 0
        private(set) var peak = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
    }

    func testNeverAdmitsMoreThanTheLimit() async throws {
        let gate = AsyncGate(limit: 2)
        let probe = Probe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await gate.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await probe.leave()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }

        let peak = await probe.peak
        XCTAssertEqual(peak, 2)
    }

    func testAWaiterThatIsCancelledNeverRunsAndLeaksNoSlot() async throws {
        let gate = AsyncGate(limit: 1)
        try await gate.acquire()   // holds the only slot

        let ran = expectation(description: "cancelled waiter ran")
        ran.isInverted = true
        let waiter = Task {
            try await gate.acquire()
            ran.fulfill()
            await gate.release()
        }
        await waitUntil(gate, hasWaiting: 1)
        waiter.cancel()

        let result = await waiter.result
        guard case .failure(let error) = result else { return XCTFail("a cancelled waiter must not acquire") }
        XCTAssertTrue(error is CancellationError)
        await fulfillment(of: [ran], timeout: 0.2)

        await gate.release()
        // The slot is free again: a new task gets in immediately rather than behind a ghost.
        let next = Task { try await gate.acquire(); await gate.release() }
        let finished = await next.result
        XCTAssertNoThrow(try finished.get())
    }

    func testWaitersAreAdmittedInArrivalOrder() async throws {
        let gate = AsyncGate(limit: 1)
        try await gate.acquire()

        let order = OrderLog()
        var tasks: [Task<Void, Error>] = []
        for index in 0..<3 {
            tasks.append(Task {
                try await gate.acquire()
                await order.append(index)
                await gate.release()
            })
            await waitUntil(gate, hasWaiting: index + 1)   // arrive one after another
        }
        await gate.release()
        for task in tasks { try await task.value }

        let admitted = await order.values
        XCTAssertEqual(admitted, [0, 1, 2])
    }

    /// Waits (up to two seconds) until `count` tasks are queued behind the gate.
    private func waitUntil(_ gate: AsyncGate, hasWaiting count: Int) async {
        for _ in 0..<400 where await gate.waitingCount < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.waitingCount
        XCTAssertGreaterThanOrEqual(waiting, count)
    }

    private actor OrderLog {
        private(set) var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }

    func testATaskCancelledBeforeItStartsNeverAcquires() async {
        let gate = AsyncGate(limit: 1)
        let task = Task {
            try await Task.sleep(for: .milliseconds(100))   // outlives the cancel below
            try await gate.acquire()
        }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get())
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AsyncGateTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'AsyncGate' in scope`.

- [ ] **Step 3: Implement**

Create `Quoote/Services/AsyncGate.swift`:

```swift
import Foundation

/// Admits at most `limit` holders at a time. The rest wait in the order they arrived, and a waiter whose task is
/// cancelled drops out without ever holding a slot.
actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// How many tasks are waiting for a slot right now. Lets a test wait for a queue to form instead of sleeping.
    var waitingCount: Int { waiters.count }

    /// Suspends until a slot is free. Throws `CancellationError` if the task is cancelled while it waits.
    /// Every `acquire()` that returns must be paired with exactly one `release()`.
    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            running -= 1
            return
        }
        // The slot passes straight to the longest-waiting task, so `running` stays put.
        waiters.removeFirst().continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AsyncGateTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 4 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/AsyncGate.swift QuooteTests/AsyncGateTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: AsyncGate, a cancellation-aware limit on concurrent loads"
```

---

### Task 7: `ThumbnailDownsampler` — image bytes in, small opaque bitmap out

ImageIO decodes straight to thumbnail size, so a 12-megapixel photo is never held at full size. The result is always opaque: a transparent PNG is flattened onto white, because it will be cached as a JPEG and JPEG has no alpha.

**Files:**
- Create: `Quoote/Services/ThumbnailDownsampler.swift`
- Create test support: `QuooteTests/TestImages.swift`
- Test: `QuooteTests/ThumbnailDownsamplerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum ThumbnailDownsampler` — `static let maxPixel = 192`; `static func downsample(url: URL, maxPixel: Int = ThumbnailDownsampler.maxPixel) -> CGImage?`; `static func downsample(data: Data, maxPixel: Int = ThumbnailDownsampler.maxPixel) -> CGImage?`; `static func jpegData(from image: CGImage, quality: CGFloat = 0.8) -> Data?`. Test support: `enum TestImages` — `bitmap(width:height:transparent:) -> CGImage`, `png(width:height:transparent:) -> Data`, `jpeg(width:height:orientation:) -> Data`, `pixel(of:x:y:) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)`.

- [ ] **Step 1: Write the failing tests**

Create the test-image helper `QuooteTests/TestImages.swift` (real image bytes from CoreGraphics and ImageIO, shared by later tasks):

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Real image bytes for tests, made with CoreGraphics and ImageIO only.
enum TestImages {

    /// A solid-colour bitmap. With `transparent`, the colour is half-transparent over a fully clear border.
    static func bitmap(width: Int, height: Int, transparent: Bool = false) -> CGImage {
        let info = transparent ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue
        )!
        if !transparent {
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            // Only the middle is painted; the corners stay fully transparent.
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
        return context.makeImage()!
    }

    static func png(width: Int, height: Int, transparent: Bool = false) -> Data {
        encode(bitmap(width: width, height: height, transparent: transparent), as: .png)
    }

    /// A JPEG, optionally tagged with an EXIF orientation (6 = the camera was held upright, pixels stored sideways).
    static func jpeg(width: Int, height: Int, orientation: Int? = nil) -> Data {
        encode(bitmap(width: width, height: height), as: .jpeg, orientation: orientation)
    }

    private static func encode(_ image: CGImage, as type: UTType, orientation: Int? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The RGBA of one pixel, `(0, 0)` being the top-left.
    static func pixel(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Shift the image so the wanted pixel lands on the one-pixel canvas.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
```

Create `QuooteTests/ThumbnailDownsamplerTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Quoote

final class ThumbnailDownsamplerTests: XCTestCase {

    func testTheLongestEdgeIsCappedAndTheAspectRatioKept() throws {
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: TestImages.png(width: 600, height: 300)))
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 96)
    }

    func testTheCapIsAMaximumNotATarget() throws {
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: TestImages.png(width: 40, height: 20)))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 192)
    }

    func testAnExifRotatedPhotoComesOutUpright() throws {
        // Stored 400x200 but tagged "rotate 90°": it is a portrait picture.
        let data = TestImages.jpeg(width: 400, height: 200, orientation: 6)
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: data))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 192)
    }

    func testATransparentPictureIsFlattenedOntoWhite() throws {
        let data = TestImages.png(width: 200, height: 200, transparent: true)
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: data))
        let corner = TestImages.pixel(of: image, x: 0, y: 0)
        XCTAssertEqual([corner.r, corner.g, corner.b, corner.a], [255, 255, 255, 255])
        let middle = TestImages.pixel(of: image, x: image.width / 2, y: image.height / 2)
        XCTAssertGreaterThan(middle.r, middle.g, "the painted part must survive")
    }

    func testBytesThatAreNotAnImageGiveNil() {
        XCTAssertNil(ThumbnailDownsampler.downsample(data: Data("not an image".utf8)))
        XCTAssertNil(ThumbnailDownsampler.downsample(data: Data()))
    }

    func testAFileOnDiskIsDownsampledWithoutReadingItAllIn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try TestImages.png(width: 800, height: 400).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(url: url))
        XCTAssertEqual(image.width, 192)
        XCTAssertNil(ThumbnailDownsampler.downsample(url: url.appendingPathExtension("missing")))
    }

    func testJPEGDataRoundTripsBackToTheSameSize() throws {
        let image = try XCTUnwrap(ThumbnailDownsampler.downsample(data: TestImages.png(width: 600, height: 300)))
        let jpeg = try XCTUnwrap(ThumbnailDownsampler.jpegData(from: image))
        let again = try XCTUnwrap(ThumbnailDownsampler.downsample(data: jpeg))
        XCTAssertEqual(again.width, image.width)
        XCTAssertEqual(again.height, image.height)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/ThumbnailDownsamplerTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'ThumbnailDownsampler' in scope`.

- [ ] **Step 3: Implement**

Create `Quoote/Services/ThumbnailDownsampler.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns image bytes into a small bitmap without ever holding the full-size one: ImageIO decodes straight to the
/// thumbnail size. Everything it returns is opaque, so a transparent PNG (a macOS screenshot with its shadow)
/// doesn't turn black when it is cached as a JPEG.
enum ThumbnailDownsampler {

    /// The longest edge, in pixels, of every thumbnail the app keeps: a 56 pt tile at 3x.
    static let maxPixel = 192

    static func downsample(url: URL, maxPixel: Int = ThumbnailDownsampler.maxPixel) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    static func downsample(data: Data, maxPixel: Int = ThumbnailDownsampler.maxPixel) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    /// JPEG bytes for the disk cache.
    static func jpegData(from image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour the EXIF orientation: a phone photo's pixels are stored sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return opaque(image)
    }

    /// The image over white, unless it has no alpha already.
    private static func opaque(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/ThumbnailDownsamplerTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 7 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/ThumbnailDownsampler.swift QuooteTests/TestImages.swift \
        QuooteTests/ThumbnailDownsamplerTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: ThumbnailDownsampler, ImageIO thumbnails that honour EXIF and flatten alpha"
```

---

### Task 8: `ThumbnailDiskCache` — Memos pictures that survive offline

A Memos picture is fetched with a token and the server marks private attachments `no-store`, so URLSession's own cache is useless. This is a small folder of JPEGs in Caches, keyed by a hash of the URL and trimmed to a size cap.

**Files:**
- Create: `Quoote/Services/ThumbnailDiskCache.swift`
- Test: `QuooteTests/ThumbnailDiskCacheTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class ThumbnailDiskCache: @unchecked Sendable` — `init(directory: URL, maxBytes: Int = 50 * 1024 * 1024, trimEvery: Int = 20)`; `static var defaultDirectory: URL` (`Caches/AttachmentThumbnails`); `static func fileName(forKey key: String) -> String` (`{sha256 hex}.jpg`); `func data(forKey:) -> Data?`; `func store(_ data: Data, forKey key: String)`; `func trim()` (oldest files first, until under the cap).

- [ ] **Step 1: Write the failing tests**

Create `QuooteTests/ThumbnailDiskCacheTests.swift`:

```swift
import XCTest
@testable import Quoote

final class ThumbnailDiskCacheTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func bytes(_ count: Int) -> Data { Data(repeating: 7, count: count) }

    func testStoredBytesComeBackAndUnknownKeysDoNot() {
        let cache = ThumbnailDiskCache(directory: directory)
        XCTAssertNil(cache.data(forKey: "https://m.example.com/a.jpg"))

        cache.store(bytes(10), forKey: "https://m.example.com/a.jpg")
        XCTAssertEqual(cache.data(forKey: "https://m.example.com/a.jpg"), bytes(10))
        XCTAssertNil(cache.data(forKey: "https://m.example.com/b.jpg"))
    }

    func testFileNamesAreAStableHashOfTheKey() {
        let name = ThumbnailDiskCache.fileName(forKey: "https://m.example.com/a.jpg")
        XCTAssertEqual(name, ThumbnailDiskCache.fileName(forKey: "https://m.example.com/a.jpg"))
        XCTAssertNotEqual(name, ThumbnailDiskCache.fileName(forKey: "https://m.example.com/b.jpg"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertEqual(name.count, 64 + 4)
        XCTAssertFalse(name.contains("/"), "a URL must never become a path")
    }

    func testTrimDropsTheOldestFilesFirstUntilItFits() throws {
        let cache = ThumbnailDiskCache(directory: directory, maxBytes: 250, trimEvery: 1_000)
        for index in 0..<5 {
            cache.store(bytes(100), forKey: "k\(index)")
            // Distinct, known ages: k0 is the oldest.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
                ofItemAtPath: directory.appendingPathComponent(ThumbnailDiskCache.fileName(forKey: "k\(index)")).path
            )
        }

        cache.trim()

        XCTAssertNil(cache.data(forKey: "k0"))
        XCTAssertNil(cache.data(forKey: "k1"))
        XCTAssertNil(cache.data(forKey: "k2"))
        XCTAssertNotNil(cache.data(forKey: "k3"))
        XCTAssertNotNil(cache.data(forKey: "k4"))
    }

    func testTrimLeavesACacheUnderTheCapAlone() {
        let cache = ThumbnailDiskCache(directory: directory, maxBytes: 1_000, trimEvery: 1_000)
        cache.store(bytes(100), forKey: "a")
        cache.store(bytes(100), forKey: "b")
        cache.trim()
        XCTAssertNotNil(cache.data(forKey: "a"))
        XCTAssertNotNil(cache.data(forKey: "b"))
    }

    func testTheCacheTrimsItselfEveryFewWrites() throws {
        let cache = ThumbnailDiskCache(directory: directory, maxBytes: 150, trimEvery: 3)
        cache.store(bytes(100), forKey: "a")
        cache.store(bytes(100), forKey: "b")
        XCTAssertNotNil(cache.data(forKey: "a"), "no trim yet: only two writes")
        // Known ages, so which file is oldest doesn't depend on the clock between writes.
        for (index, key) in ["a", "b"].enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
                ofItemAtPath: directory.appendingPathComponent(ThumbnailDiskCache.fileName(forKey: key)).path
            )
        }

        cache.store(bytes(100), forKey: "c")   // the third write triggers a trim to 150 bytes

        XCTAssertNil(cache.data(forKey: "a"))
        XCTAssertNil(cache.data(forKey: "b"))
        XCTAssertNotNil(cache.data(forKey: "c"))
    }

    func testTrimOfAFolderThatDoesNotExistYetIsHarmless() {
        ThumbnailDiskCache(directory: directory).trim()
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/ThumbnailDiskCacheTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'ThumbnailDiskCache' in scope`.

- [ ] **Step 3: Implement**

Create `Quoote/Services/ThumbnailDiskCache.swift`:

```swift
import CryptoKit
import Foundation

/// A size-capped folder of small JPEGs, one per remote image, named by the SHA-256 of the URL it came from.
///
/// It lives in Caches, so iOS may clear it whenever storage runs low — everything in it can be fetched again.
/// A hit short-circuits the network, which is what keeps thumbnails showing offline.
final class ThumbnailDiskCache: @unchecked Sendable {

    let directory: URL
    private let maxBytes: Int
    private let trimEvery: Int
    private let lock = NSLock()
    private var writesSinceTrim = 0

    init(directory: URL, maxBytes: Int = 50 * 1024 * 1024, trimEvery: Int = 20) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.trimEvery = max(1, trimEvery)
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AttachmentThumbnails", isDirectory: true)
    }

    static func fileName(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(forKey: key)))
    }

    func store(_ data: Data, forKey key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(forKey: key))
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }

        lock.lock()
        writesSinceTrim += 1
        let due = writesSinceTrim >= trimEvery
        if due { writesSinceTrim = 0 }
        lock.unlock()
        if due { trim() }
    }

    /// Deletes the oldest files until what is left fits under the cap.
    func trim() {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        var files: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        files.sort { $0.date < $1.date }
        for file in files where total > maxBytes {
            if (try? manager.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/ThumbnailDiskCacheTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 6 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/ThumbnailDiskCache.swift QuooteTests/ThumbnailDiskCacheTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: ThumbnailDiskCache, a size-capped folder of Memos thumbnails"
```


---

### Task 9: `MemosAttachmentFetcher` — the only code that talks to the Memos server for pictures

Where a picture may come from, and nothing else: a URL on any origin but the configured Memos server gets no request, so neither the API token nor the device's address goes to a stranger's server. For an uploaded attachment it asks for the server's 600 px thumbnail first and falls back to the original (older servers, types the server can't thumbnail).

**Files:**
- Create: `Quoote/Services/MemosAttachmentFetcher.swift`
- Create test support: `QuooteTests/AttachmentStubURLProtocol.swift`
- Test: `QuooteTests/MemosAttachmentFetcherTests.swift`

**Interfaces:**
- Consumes: `NoteAttachments.isAbsoluteURL(_:)`, `NoteAttachments.isMemosRelative(_:)` (Task 1); `ThumbnailDownsampler.downsample(data:maxPixel:)` (Task 7); `TestImages` (Task 7, tests only).
- Produces:
  - `struct MemosOrigin: Equatable` — `init?(url: URL)` (scheme, lowercased host, port with 80/443 defaults)
  - `struct MemosAttachmentFetcher` — `struct Configuration { var endpoint: String; var token: String; var allowInsecureHTTP: Bool }`; `static let defaultMaxBytes = 10 * 1024 * 1024`; memberwise `init(session: URLSession, configuration: @escaping @Sendable () -> Configuration, maxBytes: Int = defaultMaxBytes, timeout: TimeInterval = 15)`; `func candidateURLs(for target: String) -> [URL]` (thumbnail URL first, then the plain URL; empty when the target must not be fetched); `func image(for target: String, maxPixel: Int) async -> CGImage?`
  - Test support: `final class AttachmentStubURLProtocol: URLProtocol` — `enum Reply { case data(Data, status: Int = 200, headers: [String: String] = [:], delay: TimeInterval = 0), redirect(to: URL), hang, fail(URLError.Code) }`; `static func reset(_ handler: @escaping (URLRequest) -> Reply)`; `static func session() -> URLSession`; `static var requests: [URLRequest]`, `peakConcurrency: Int`, `cancelledCount: Int`

- [ ] **Step 1: Write the failing tests**

Create the stub server `QuooteTests/AttachmentStubURLProtocol.swift` (answers from a closure, and counts requests, concurrency and cancellations):

```swift
import Foundation

/// A URLProtocol that answers from a closure and keeps score: which requests arrived, how many were in flight at
/// once, how many were cancelled before they were answered. State is static, so each test calls `reset` first.
final class AttachmentStubURLProtocol: URLProtocol {

    enum Reply {
        /// Answers after `delay` seconds.
        case data(Data, status: Int = 200, headers: [String: String] = [:], delay: TimeInterval = 0)
        case redirect(to: URL)
        /// Never answers; only a cancellation ends it.
        case hang
        case fail(URLError.Code)
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var seen: [URLRequest] = []
    private static var inFlight = 0
    private static var peak = 0
    private static var cancellations = 0

    static func reset(_ handler: @escaping (URLRequest) -> Reply = { _ in .fail(.notConnectedToInternet) }) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        seen = []; inFlight = 0; peak = 0; cancellations = 0
    }

    /// A session whose every request goes to the stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttachmentStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static var peakConcurrency: Int { lock.lock(); defer { lock.unlock() }; return peak }
    static var cancelledCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }

    private let state = NSLock()
    private var finished = false
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        Self.inFlight += 1
        Self.peak = max(Self.peak, Self.inFlight)
        let reply = Self.handler?(request) ?? .fail(.notConnectedToInternet)
        Self.lock.unlock()

        switch reply {
        case .data(let data, let status, let headers, let delay):
            let deliver = { [self] in
                state.lock(); let abandoned = stopped; state.unlock()
                guard !abandoned else { return }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                markFinished()
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
            } else {
                deliver()
            }
        case .redirect(let url):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
            // A client that follows the redirect stops this load. One that declines keeps it alive and expects the
            // 3xx itself to be delivered as the answer, which is what happens here once the client has had its say.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                state.lock(); let abandoned = stopped; state.unlock()
                guard !abandoned else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                markFinished()
            }
        case .hang:
            break
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
            markFinished()
        }
    }

    override func stopLoading() {
        state.lock()
        stopped = true
        let wasAnswered = finished
        finished = true
        state.unlock()
        guard !wasAnswered else { return }
        Self.lock.lock()
        Self.inFlight -= 1
        Self.cancellations += 1
        Self.lock.unlock()
    }

    private func markFinished() {
        state.lock()
        let already = finished
        finished = true
        state.unlock()
        guard !already else { return }
        Self.lock.lock()
        Self.inFlight -= 1
        Self.lock.unlock()
    }
}
```

Create `QuooteTests/MemosAttachmentFetcherTests.swift`:

```swift
import XCTest
@testable import Quoote

final class MemosAttachmentFetcherTests: XCTestCase {

    private let png = TestImages.png(width: 600, height: 300)

    override func setUp() {
        super.setUp()
        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
    }

    override func tearDown() {
        AttachmentStubURLProtocol.reset()
        super.tearDown()
    }

    private func fetcher(
        endpoint: String = "https://memos.example.com",
        token: String = "tok",
        allowInsecureHTTP: Bool = false,
        maxBytes: Int = MemosAttachmentFetcher.defaultMaxBytes
    ) -> MemosAttachmentFetcher {
        MemosAttachmentFetcher(
            session: AttachmentStubURLProtocol.session(),
            configuration: { .init(endpoint: endpoint, token: token, allowInsecureHTTP: allowInsecureHTTP) },
            maxBytes: maxBytes
        )
    }

    private func urls() -> [String] {
        AttachmentStubURLProtocol.requests.compactMap { $0.url?.absoluteString }
    }

    // MARK: What gets requested

    func testAMemosRelativeTargetAsksForTheThumbnailWithTheToken() async throws {
        let image = await fetcher().image(for: "/file/attachments/u/image.jpg", maxPixel: 192)

        XCTAssertEqual(image?.width, 192)
        XCTAssertEqual(urls(), ["https://memos.example.com/file/attachments/u/image.jpg?thumbnail=true"])
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testThePlainURLIsTheFallbackWhenTheThumbnailFails() async {
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.query?.contains("thumbnail=true") == true ? .data(Data(), status: 500) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/image.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(urls(), [
            "https://memos.example.com/file/attachments/u/image.jpg?thumbnail=true",
            "https://memos.example.com/file/attachments/u/image.jpg",
        ])
    }

    func testAThumbnailThatIsNotAPictureFallsBackToThePlainURL() async {
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.query?.contains("thumbnail=true") == true ? .data(Data("<html>".utf8)) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/image.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(urls().count, 2)
    }

    func testOlderServerPathsAreFetchedAsIs() async {
        let image = await fetcher().image(for: "/o/r/12/a.png", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(urls(), ["https://memos.example.com/o/r/12/a.png"])
    }

    func testAnExistingQueryIsKeptWhenTheThumbnailFlagIsAdded() {
        let candidates = fetcher().candidateURLs(for: "https://memos.example.com/file/attachments/u/a.jpg?x=1")
        XCTAssertEqual(candidates.map(\.absoluteString), [
            "https://memos.example.com/file/attachments/u/a.jpg?x=1&thumbnail=true",
            "https://memos.example.com/file/attachments/u/a.jpg?x=1",
        ])
    }

    func testASubpathInstallKeepsItsPrefix() {
        let candidates = fetcher(endpoint: "https://example.com/memos/").candidateURLs(for: "/file/attachments/u/a.jpg")
        XCTAssertEqual(candidates.map(\.absoluteString), [
            "https://example.com/memos/file/attachments/u/a.jpg?thumbnail=true",
            "https://example.com/memos/file/attachments/u/a.jpg",
        ])
    }

    func testFilenamesWithSpacesAndNonLatinLettersStillMakeARequest() async {
        let image = await fetcher().image(for: "/file/attachments/u/My Photo é 写真.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.url?.host, "memos.example.com")
    }

    func testAVaultTargetIsNeverFetched() {
        XCTAssertEqual(fetcher().candidateURLs(for: "photo.png"), [])
        XCTAssertEqual(fetcher().candidateURLs(for: "/photo.png"), [])
    }

    // MARK: Who gets asked

    func testAnotherHostGetsNoRequestAtAll() async {
        let image = await fetcher().image(for: "https://evil.example.net/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty, "the token must not go anywhere else")
    }

    func testAnAbsoluteURLOnTheMemosOriginIsFetchedWithTheToken() async {
        let image = await fetcher().image(for: "https://memos.example.com/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testOriginsAreComparedIgnoringCaseAndDefaultPorts() async {
        let sameOrigin = fetcher(endpoint: "https://Memos.Example.com:443/")
        let image = await sameOrigin.image(for: "https://memos.example.com/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNotNil(image)

        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
        let otherPort = await fetcher().image(for: "https://memos.example.com:8443/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNil(otherPort)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testTheSchemeMustMatchSoTheTokenNeverTravelsOverPlainHTTP() async {
        let image = await fetcher().image(for: "http://memos.example.com/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testAPlainHTTPEndpointIsOnlyUsedWhenSettingsAllowIt() async {
        let refused = await fetcher(endpoint: "http://192.168.1.5:5230").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNil(refused)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)

        let allowed = await fetcher(endpoint: "http://192.168.1.5:5230", allowInsecureHTTP: true)
            .image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNotNil(allowed)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.url?.port, 5230)
    }

    func testNoEndpointOrNoTokenMeansNoRequest() async {
        let noEndpoint = await fetcher(endpoint: "  ").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        let noToken = await fetcher(token: " ").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        let badScheme = await fetcher(endpoint: "ftp://memos.example.com").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(noEndpoint)
        XCTAssertNil(noToken)
        XCTAssertNil(badScheme)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testARedirectToAnotherHostIsNotFollowed() async {
        let evil = URL(string: "https://evil.example.net/x.png")!
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.host == "memos.example.com" ? .redirect(to: evil) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertFalse(urls().contains { $0.contains("evil.example.net") }, "the redirect must not be followed")
    }

    func testARedirectWithinTheMemosOriginIsFollowedWithTheToken() async {
        let elsewhere = URL(string: "https://memos.example.com/moved/a.png")!
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.path.hasPrefix("/file/") == true ? .redirect(to: elsewhere) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.last?.url, elsewhere)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    // MARK: Limits and failures

    func testABodyOverTheCapIsAbandoned() async {
        AttachmentStubURLProtocol.reset { _ in .data(Data(repeating: 1, count: 2_000)) }

        let image = await fetcher(maxBytes: 1_000).image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
    }

    func testADeclaredLengthOverTheCapIsRefusedBeforeReadingAnything() async {
        AttachmentStubURLProtocol.reset { [png] _ in .data(png, headers: ["Content-Length": "5000000"]) }

        let image = await fetcher(maxBytes: 1_000_000).image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image, "5 MB promised against a 1 MB cap: refused on the headers alone")
    }

    func testAnErrorStatusIsNoPicture() async {
        AttachmentStubURLProtocol.reset { _ in .data(Data("nope".utf8), status: 401) }

        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertEqual(urls().count, 2, "thumbnail, then the plain URL")
    }

    func testANetworkErrorIsNoPicture() async {
        AttachmentStubURLProtocol.reset { _ in .fail(.notConnectedToInternet) }
        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNil(image)
    }

    func testCancellingTheTaskCancelsTheRequest() async throws {
        AttachmentStubURLProtocol.reset { _ in .hang }
        let task = Task { await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192) }

        while AttachmentStubURLProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let image = await task.value
        // URLSession reports the cancellation to the protocol a moment later.
        for _ in 0..<100 where AttachmentStubURLProtocol.cancelledCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.cancelledCount, 1)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1, "no fallback request after a cancel")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/MemosAttachmentFetcherTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'MemosAttachmentFetcher' in scope`.

- [ ] **Step 3: Implement**

Create `Quoote/Services/MemosAttachmentFetcher.swift`:

```swift
import CoreGraphics
import Foundation

/// The scheme, host and port a URL must share with the configured Memos server before the app sends it a request.
struct MemosOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

/// Fetches an attachment's picture from the configured Memos server — and from nowhere else. A URL on any other
/// origin gets no request, so neither the API token nor the device's address goes to a stranger's server.
struct MemosAttachmentFetcher {

    struct Configuration {
        var endpoint: String
        var token: String
        var allowInsecureHTTP: Bool
    }

    static let defaultMaxBytes = 10 * 1024 * 1024

    let session: URLSession
    /// Read on every call, so a change in Settings applies to the next load.
    let configuration: @Sendable () -> Configuration
    var maxBytes = MemosAttachmentFetcher.defaultMaxBytes
    var timeout: TimeInterval = 15

    /// The URLs to try, best first: for an uploaded attachment the server's 600 px thumbnail, then the file
    /// itself (an older server, a type it can't thumbnail). Empty when the target must not be fetched.
    func candidateURLs(for target: String) -> [URL] {
        plan(for: target)?.urls ?? []
    }

    /// The picture, at most `maxPixel` on its longest edge, or `nil`. Never throws: a failure of any kind is
    /// just "no picture".
    func image(for target: String, maxPixel: Int) async -> CGImage? {
        guard let plan = plan(for: target) else { return nil }
        let redirects = OriginPinnedRedirects(origin: plan.origin, token: plan.token)
        for url in plan.urls {
            if Task.isCancelled { return nil }
            guard let data = await fetch(url, token: plan.token, redirects: redirects) else { continue }
            // A thumbnail the server couldn't make comes back as the original; one that isn't a picture at all
            // falls through to the next URL.
            if let image = ThumbnailDownsampler.downsample(data: data, maxPixel: maxPixel) { return image }
        }
        return nil
    }

    private func plan(for target: String) -> (urls: [URL], token: String, origin: MemosOrigin)? {
        let settings = configuration()
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let base = Self.baseURL(from: settings), let origin = MemosOrigin(url: base) else {
            return nil
        }

        let resolved: URL?
        if NoteAttachments.isAbsoluteURL(target) {
            resolved = URL(string: target)
        } else if NoteAttachments.isMemosRelative(target) {
            resolved = URL(string: base.absoluteString + target)
        } else {
            resolved = nil
        }
        guard let url = resolved, MemosOrigin(url: url) == origin else { return nil }

        guard url.path.contains("/file/attachments/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ([url], token, origin)
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "thumbnail" }) {
            items.append(URLQueryItem(name: "thumbnail", value: "true"))
        }
        components.queryItems = items
        guard let thumbnail = components.url else { return ([url], token, origin) }
        return ([thumbnail, url], token, origin)
    }

    /// The same rules `MemosClient` applies to the endpoint: trimmed, no trailing slashes, http(s) only, and
    /// plain http only when Settings allows it.
    private static func baseURL(from settings: Configuration) -> URL? {
        let trimmed = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "https" || (scheme == "http" && settings.allowInsecureHTTP) else { return nil }
        return url
    }

    /// One GET, streamed so a body over `maxBytes` is abandoned as soon as it crosses the line.
    private func fetch(_ url: URL, token: String, redirects: URLSessionTaskDelegate) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            if http.expectedContentLength > Int64(maxBytes) { return nil }

            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return data
        } catch {
            return nil
        }
    }
}

/// Follows a redirect only while it stays on the Memos origin, carrying the token along. A redirect anywhere else
/// is not followed — the 3xx answer is the result — so the token cannot be handed on to another host.
private final class OriginPinnedRedirects: NSObject, URLSessionTaskDelegate {
    private let origin: MemosOrigin
    private let token: String

    init(origin: MemosOrigin, token: String) {
        self.origin = origin
        self.token = token
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, MemosOrigin(url: url) == origin else {
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/MemosAttachmentFetcherTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 21 tests, with 0 failures` and `** TEST SUCCEEDED **`, in a second or two. (A run that takes 15–30 s means a stubbed redirect or request is hanging until its timeout: look at which test.)

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/MemosAttachmentFetcher.swift QuooteTests/AttachmentStubURLProtocol.swift \
        QuooteTests/MemosAttachmentFetcherTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: MemosAttachmentFetcher, pictures from the Memos origin only"
```

---

### Task 10: Finding and reading a vault picture

An Obsidian wikilink names a file, not a path: `![[photo 1.jpg]]` may live in the attachments folder, at the vault root, beside the note, or anywhere. This is the lookup, plus a thumbnail read that never touches an evicted iCloud file.

**Files:**
- Create: `Quoote/Services/Vault/VaultFileStore+Attachments.swift`
- Test: `QuooteTests/VaultFileStoreAttachmentTests.swift`

**Interfaces:**
- Consumes: `ThumbnailDownsampler.downsample(url:maxPixel:)` (Task 7); `TestImages` (Task 7, tests only); the existing `VaultFileStore.mappedFilename(_:)` and `requestDownload(relativePath:)`.
- Produces, on `VaultFileStore`: `enum AttachmentThumbnail { case image(CGImage, modifiedAt: Date); case notDownloaded; case unreadable }`; `func locateAttachment(_ target: String, attachmentsFolder: String, notePath: String?) -> String?`; `func attachmentModificationDate(at relativePath: String) -> Date?`; `func attachmentThumbnail(at relativePath: String, maxPixel: Int) -> AttachmentThumbnail`.

- [ ] **Step 1: Write the failing tests**

Create `QuooteTests/VaultFileStoreAttachmentTests.swift`:

```swift
import XCTest
@testable import Quoote

final class VaultFileStoreAttachmentTests: XCTestCase {

    private var root: URL!
    private var store: VaultFileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultFileStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func put(_ relativePath: String, _ data: Data = Data("x".utf8)) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func locate(_ target: String, folder: String = "attachments", note: String? = nil) -> String? {
        store.locateAttachment(target, attachmentsFolder: folder, notePath: note)
    }

    // MARK: Where a target lives

    func testTheAttachmentsFolderIsLookedInFirst() throws {
        try put("attachments/a.png")
        try put("a.png")
        try put("notes/a.png")
        XCTAssertEqual(locate("a.png", note: "notes/n.md"), "attachments/a.png")
    }

    func testThenTheVaultRoot() throws {
        try put("a.png")
        try put("notes/a.png")
        XCTAssertEqual(locate("a.png", note: "notes/n.md"), "a.png")
    }

    func testThenTheFolderOfTheNoteThatLinksIt() throws {
        try put("notes/a.png")
        try put("elsewhere/a.png")
        XCTAssertEqual(locate("a.png", note: "notes/n.md"), "notes/a.png")
    }

    func testThenAnywhereInTheVaultIgnoringCase() throws {
        try put("Deep/Er/Photo.PNG")
        XCTAssertEqual(locate("photo.png"), "Deep/Er/Photo.PNG")
    }

    func testAPathTargetIsTriedAsWritten() throws {
        try put("assets/2024/a.png")
        XCTAssertEqual(locate("assets/2024/a.png", folder: ""), "assets/2024/a.png")
        XCTAssertEqual(locate("2024/a.png", folder: "assets"), "assets/2024/a.png")
    }

    func testAnAttachmentsFolderSettingOfNothingMeansTheRoot() throws {
        try put("a.png")
        XCTAssertEqual(locate("a.png", folder: ""), "a.png")
    }

    func testAMissingFileIsNil() {
        XCTAssertNil(locate("nope.png"))
    }

    func testTargetsThatEscapeTheVaultAreRefused() throws {
        try put("secret/a.png")
        XCTAssertNil(locate("../a.png"))
        XCTAssertNil(locate("attachments/../../a.png"))
        XCTAssertNil(locate("/etc/hosts"))
        XCTAssertNil(locate("/a.png"))
        XCTAssertNil(locate(""))
        XCTAssertNil(locate("./a.png"))
    }

    func testTheWalkSkipsObsidianConfigTheTrashAndHiddenFolders() throws {
        try put(".obsidian/a.png")
        try put(".trash/a.png")
        try put(".hidden/a.png")
        XCTAssertNil(locate("a.png"))

        try put("kept/a.png")
        XCTAssertEqual(locate("a.png"), "kept/a.png")
    }

    func testAFolderNamedLikeTheFileIsNotTheFile() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("a.png"), withIntermediateDirectories: true)
        XCTAssertNil(locate("a.png", folder: ""), "a directory is not a picture")
    }

    // MARK: iCloud placeholders

    func testAnEvictedFileIsFoundThroughItsPlaceholderUnderTheRealName() throws {
        try put("attachments/.photo.jpg.icloud")
        XCTAssertEqual(locate("photo.jpg"), "attachments/photo.jpg")
    }

    func testAnEvictedFileFoundByTheWalkIsReportedUnderTheRealName() throws {
        try put("deep/folder/.photo.jpg.icloud")
        XCTAssertEqual(locate("photo.jpg"), "deep/folder/photo.jpg")
    }

    func testAPlaceholderIsNeverReadAsAPicture() throws {
        try put("attachments/.photo.jpg.icloud", Data("placeholder, not image bytes".utf8))

        guard case .notDownloaded = store.attachmentThumbnail(at: "attachments/photo.jpg", maxPixel: 192) else {
            return XCTFail("an evicted file must report .notDownloaded, not be read")
        }
    }

    // MARK: Thumbnails

    func testAPictureComesBackDownsampledWithItsModificationDate() throws {
        try put("attachments/p.png", TestImages.png(width: 600, height: 300))

        guard case .image(let image, let modified) = store.attachmentThumbnail(at: "attachments/p.png", maxPixel: 192) else {
            return XCTFail("expected an image")
        }
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 96)
        XCTAssertEqual(modified, store.attachmentModificationDate(at: "attachments/p.png"))
    }

    func testAFileThatIsNotAPictureIsUnreadable() throws {
        try put("attachments/notes.txt", Data("just words".utf8))
        guard case .unreadable = store.attachmentThumbnail(at: "attachments/notes.txt", maxPixel: 192) else {
            return XCTFail("expected .unreadable")
        }
    }

    func testAFileThatIsNotThereIsUnreadable() {
        guard case .unreadable = store.attachmentThumbnail(at: "attachments/gone.png", maxPixel: 192) else {
            return XCTFail("expected .unreadable")
        }
        XCTAssertNil(store.attachmentModificationDate(at: "attachments/gone.png"))
    }

    func testAReplacedFileHasANewModificationDate() throws {
        try put("a.png", TestImages.png(width: 100, height: 100))
        let before = store.attachmentModificationDate(at: "a.png")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: root.appendingPathComponent("a.png").path
        )
        XCTAssertNotEqual(store.attachmentModificationDate(at: "a.png"), before)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/VaultFileStoreAttachmentTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `value of type 'VaultFileStore' has no member 'locateAttachment'`.

- [ ] **Step 3: Implement**

Create `Quoote/Services/Vault/VaultFileStore+Attachments.swift`:

```swift
import CoreGraphics
import Foundation

/// Reading the pictures a note links to. Like the rest of `VaultFileStore`, `root` is injected, so all of this is
/// testable against a temp directory.
extension VaultFileStore {

    /// What reading an attachment's thumbnail produced.
    enum AttachmentThumbnail {
        case image(CGImage, modifiedAt: Date)
        /// iCloud has evicted the file. A download was requested and nothing was read — reading would block on it.
        case notDownloaded
        /// Missing, not a picture, or unreadable.
        case unreadable
    }

    /// The vault-relative path of the file a wikilink or embed `target` names, or `nil`. Tried in order, each
    /// accepting the file or its iCloud placeholder:
    ///
    /// 1. the attachments folder, 2. the vault root, 3. the folder of the note that links it, 4. the first file
    /// anywhere in the vault with that name, ignoring case.
    ///
    /// A target that climbs out of the vault (`..`) or starts at `/` is refused.
    func locateAttachment(_ target: String, attachmentsFolder: String, notePath: String?) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last, !components.contains(".."), !components.contains(".") else { return nil }
        let relative = components.joined(separator: "/")

        var candidates: [String] = []
        if !attachmentsFolder.isEmpty { candidates.append("\(attachmentsFolder)/\(relative)") }
        candidates.append(relative)
        if let notePath {
            let folder = (notePath as NSString).deletingLastPathComponent
            if !folder.isEmpty { candidates.append("\(folder)/\(relative)") }
        }
        for candidate in candidates where attachmentIsPresent(at: candidate) { return candidate }
        return findAttachment(named: name)
    }

    /// When the file was last changed, or `nil` if it isn't on disk (an evicted file has only its placeholder).
    func attachmentModificationDate(at relativePath: String) -> Date? {
        let url = root.appendingPathComponent(relativePath)
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// A thumbnail of the picture at `relativePath`, at most `maxPixel` on its longest edge. The full-size bitmap
    /// is never held: ImageIO decodes straight to the thumbnail.
    func attachmentThumbnail(at relativePath: String, maxPixel: Int) -> AttachmentThumbnail {
        let url = root.appendingPathComponent(relativePath)
        let manager = FileManager.default

        guard manager.fileExists(atPath: url.path) else {
            guard manager.fileExists(atPath: placeholderURL(for: relativePath).path) else { return .unreadable }
            requestDownload(relativePath: relativePath)
            return .notDownloaded
        }

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            requestDownload(relativePath: relativePath)
            return .notDownloaded
        }

        var coordinationError: NSError?
        var image: CGImage?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            image = ThumbnailDownsampler.downsample(url: readURL, maxPixel: maxPixel)
        }
        guard coordinationError == nil, let image else { return .unreadable }
        return .image(image, modifiedAt: values?.contentModificationDate ?? .distantPast)
    }

    // MARK: - Helpers

    /// `Docs/.report.pdf.icloud` for `Docs/report.pdf`: where iCloud leaves an evicted file.
    private func placeholderURL(for relativePath: String) -> URL {
        let url = root.appendingPathComponent(relativePath)
        return url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// A file (not a folder) is there, or its iCloud placeholder is.
    private func attachmentIsPresent(at relativePath: String) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: root.appendingPathComponent(relativePath).path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return true
        }
        return manager.fileExists(atPath: placeholderURL(for: relativePath).path)
    }

    /// The first file in the vault named `name`, ignoring case. Skips `.obsidian`, `.trash` and any other hidden
    /// folder or file — except an iCloud placeholder, which is reported under the real name.
    private func findAttachment(named name: String) -> String? {
        let wanted = name.lowercased()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }

        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let leaf = url.lastPathComponent
            let realLeaf = Self.mappedFilename(leaf)
            let isPlaceholder = realLeaf != leaf

            if leaf.hasPrefix(".") && !isPlaceholder {
                enumerator.skipDescendants()
                continue
            }
            guard realLeaf.lowercased() == wanted else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if isPlaceholder {
                relative = ((relative as NSString).deletingLastPathComponent as NSString).appendingPathComponent(realLeaf)
            }
            return relative
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/VaultFileStoreAttachmentTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 17 tests, with 0 failures` and `** TEST SUCCEEDED **`. The first file-coordinated read in a fresh simulator process can take several seconds (the simulator starts its file-coordination service); that is expected, not a hang.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/Vault/VaultFileStore+Attachments.swift QuooteTests/VaultFileStoreAttachmentTests.swift \
        Quoote.xcodeproj/project.pbxproj
git commit -m "feat: find a wikilink's file in the vault and read its thumbnail"
```


---

### Task 11: `AttachmentThumbnailLoader` — one door from a reference to pixels

The orchestrator. Nothing loads until a tile asks; two caches sit in front; identical requests share one task; a load nobody waits for any more is cancelled; at most four run at once; every failure is silent and remembered for a minute.

**Files:**
- Create: `Quoote/Services/AttachmentThumbnailLoader.swift`
- Test: `QuooteTests/AttachmentThumbnailLoaderTests.swift`

**Interfaces:**
- Consumes: `NoteAttachment` (Task 1); `AsyncGate` (Task 6); `ThumbnailDownsampler` (Task 7); `ThumbnailDiskCache` (Task 8); `MemosAttachmentFetcher` (Task 9); `VaultFileStore.locateAttachment/attachmentModificationDate/attachmentThumbnail` (Task 10); `AppSettings`, `KeychainTokenStore`, `VaultBookmarkStore.withAccess` (existing); `AttachmentStubURLProtocol`, `TestImages` (tests only).
- Produces: `final class AttachmentThumbnailLoader: @unchecked Sendable` — `static let shared`; `static let maxPixel`; `static let failureMemory: TimeInterval` (60); `struct Environment { var session, endpoint, token, allowInsecureHTTP, vaultAccess, attachmentsFolder, diskCache, now, maxConcurrentLoads (4), maxFetchBytes }` with `static var live`; `init(environment:)`; `func cachedImage(for attachment: NoteAttachment, notePath: String?) -> UIImage?` (synchronous, memory only); `func thumbnail(for attachment: NoteAttachment, notePath: String?) async -> UIImage?`. Only `.image` attachments load; a file gets `nil`.

- [ ] **Step 1: Write the failing tests**

Create `QuooteTests/AttachmentThumbnailLoaderTests.swift`:

```swift
import XCTest
import UIKit
@testable import Quoote

final class AttachmentThumbnailLoaderTests: XCTestCase {

    private var tempDirectory: URL!
    private var vaultRoot: URL!
    private let png = TestImages.png(width: 600, height: 300)

    /// A clock the tests move by hand, to step over the one-minute failure memory.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    }
    private let clock = Clock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultRoot = tempDirectory.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
    }

    override func tearDownWithError() throws {
        AttachmentStubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func makeLoader(connectedVault: Bool = true, maxConcurrentLoads: Int = 4) -> AttachmentThumbnailLoader {
        let root = vaultRoot!
        let clock = clock
        return AttachmentThumbnailLoader(environment: .init(
            session: AttachmentStubURLProtocol.session(),
            endpoint: { "https://memos.example.com" },
            token: { "tok" },
            allowInsecureHTTP: { false },
            vaultAccess: { body in connectedVault ? body(VaultFileStore(root: root)) : nil },
            attachmentsFolder: { "attachments" },
            diskCache: ThumbnailDiskCache(directory: tempDirectory.appendingPathComponent("thumbs")),
            now: { clock.now },
            maxConcurrentLoads: maxConcurrentLoads
        ))
    }

    private func image(_ target: String) -> NoteAttachment {
        NoteAttachment(target: target, name: (target as NSString).lastPathComponent, kind: .image)
    }

    private func put(_ relativePath: String, _ data: Data) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func waitForFirstRequest() async throws {
        while AttachmentStubURLProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Vault pictures

    func testAVaultPictureLoadsThenIsServedFromMemory() async throws {
        try put("attachments/p.png", png)
        let loader = makeLoader()
        let attachment = image("p.png")
        XCTAssertNil(loader.cachedImage(for: attachment, notePath: nil))

        let loaded = await loader.thumbnail(for: attachment, notePath: nil)

        let picture = try XCTUnwrap(loaded)
        XCTAssertEqual(picture.size, CGSize(width: 192, height: 96))
        XCTAssertTrue(loader.cachedImage(for: attachment, notePath: nil) === picture)
    }

    func testAnUnchangedVaultFileIsNotDecodedAgain() async throws {
        try put("attachments/p.png", png)
        let loader = makeLoader()

        let first = await loader.thumbnail(for: image("p.png"), notePath: nil)
        let second = await loader.thumbnail(for: image("p.png"), notePath: nil)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    func testAReplacedVaultFileIsLoadedAgain() async throws {
        try put("attachments/p.png", png)
        let loader = makeLoader()
        let first = await loader.thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertEqual(first?.size, CGSize(width: 192, height: 96))

        try put("attachments/p.png", TestImages.png(width: 100, height: 300))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: vaultRoot.appendingPathComponent("attachments/p.png").path
        )
        let second = await loader.thumbnail(for: image("p.png"), notePath: nil)

        XCTAssertEqual(second?.size.height, 192)
        XCTAssertLessThan(second?.size.width ?? 999, 100)
    }

    func testTheSameTargetInTwoNoteFoldersIsTwoPictures() async throws {
        try put("a/pic.png", TestImages.png(width: 300, height: 300))
        try put("b/pic.png", TestImages.png(width: 300, height: 100))
        let loader = makeLoader()

        let first = await loader.thumbnail(for: image("pic.png"), notePath: "a/note.md")
        let second = await loader.thumbnail(for: image("pic.png"), notePath: "b/note.md")

        XCTAssertEqual(first?.size, CGSize(width: 192, height: 192))
        XCTAssertEqual(second?.size, CGSize(width: 192, height: 64))
    }

    func testAMissingFileIsRetriedAfterAMinuteSoALateSyncShowsUp() async throws {
        let loader = makeLoader()
        let miss = await loader.thumbnail(for: image("late.png"), notePath: nil)
        XCTAssertNil(miss)

        try put("attachments/late.png", png)   // it syncs in
        let tooSoon = await loader.thumbnail(for: image("late.png"), notePath: nil)
        XCTAssertNil(tooSoon, "a failure is remembered for a minute")

        clock.advance(61)
        let later = await loader.thumbnail(for: image("late.png"), notePath: nil)
        XCTAssertNotNil(later)
    }

    func testAnEvictedFileStaysOnItsIconAndComesBackWhenItsDownloaded() async throws {
        try put("attachments/.p.png.icloud", Data("placeholder".utf8))
        let loader = makeLoader()
        let evicted = await loader.thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertNil(evicted)

        try FileManager.default.removeItem(at: vaultRoot.appendingPathComponent("attachments/.p.png.icloud"))
        try put("attachments/p.png", png)
        clock.advance(61)
        let back = await loader.thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertNotNil(back)
    }

    func testWithoutAConnectedVaultThereIsNoPictureAndNoCrash() async {
        let result = await makeLoader(connectedVault: false).thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertNil(result)
    }

    // MARK: Memos pictures

    func testAMemosPictureIsFetchedOnceThenServedFromMemory() async {
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")

        let first = await loader.thumbnail(for: attachment, notePath: nil)
        let second = await loader.thumbnail(for: attachment, notePath: nil)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)
    }

    func testAMemosPictureIsKeptOnDiskSoItShowsOffline() async {
        let attachment = image("/file/attachments/u/a.jpg")
        _ = await makeLoader().thumbnail(for: attachment, notePath: nil)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)

        AttachmentStubURLProtocol.reset { _ in .fail(.notConnectedToInternet) }
        let relaunched = makeLoader()   // empty memory, same folder on disk
        let offline = await relaunched.thumbnail(for: attachment, notePath: nil)

        XCTAssertNotNil(offline)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testAPictureOnAnotherHostIsNeverRequested() async {
        let result = await makeLoader().thumbnail(for: image("https://evil.example.net/a.png"), notePath: nil)

        XCTAssertNil(result)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testAFailedDownloadIsNotRetriedForAMinute() async {
        AttachmentStubURLProtocol.reset { _ in .data(Data(), status: 500) }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")

        let first = await loader.thumbnail(for: attachment, notePath: nil)
        XCTAssertNil(first)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 2, "the thumbnail, then the plain URL")

        let second = await loader.thumbnail(for: attachment, notePath: nil)
        XCTAssertNil(second)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 2, "no new request inside the minute")

        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
        clock.advance(61)
        let third = await loader.thumbnail(for: attachment, notePath: nil)
        XCTAssertNotNil(third)
    }

    // MARK: Sharing, cancelling, limiting

    func testTheSamePictureAskedForAtOnceIsFetchedOnce() async {
        AttachmentStubURLProtocol.reset { [png] _ in .data(png, delay: 0.3) }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")

        async let first = loader.thumbnail(for: attachment, notePath: nil)
        async let second = loader.thumbnail(for: attachment, notePath: "x/y.md")
        async let third = loader.thumbnail(for: attachment, notePath: nil)
        let results = await [first, second, third]

        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)
    }

    func testTheDownloadIsCancelledOnlyWhenTheLastWaiterLeaves() async throws {
        AttachmentStubURLProtocol.reset { _ in .hang }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")
        let first = Task { await loader.thumbnail(for: attachment, notePath: nil) }
        let second = Task { await loader.thumbnail(for: attachment, notePath: nil) }
        try await waitForFirstRequest()
        try await Task.sleep(for: .milliseconds(100))   // both are waiting by now

        first.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(AttachmentStubURLProtocol.cancelledCount, 0, "one waiter is still interested")

        second.cancel()
        for _ in 0..<100 where AttachmentStubURLProtocol.cancelledCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(AttachmentStubURLProtocol.cancelledCount, 1)
        _ = await first.value
        _ = await second.value
    }

    func testACancelledLoadIsNotRememberedAsAFailure() async throws {
        AttachmentStubURLProtocol.reset { _ in .hang }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")
        let task = Task { await loader.thumbnail(for: attachment, notePath: nil) }
        try await waitForFirstRequest()
        task.cancel()
        _ = await task.value

        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
        let retried = await loader.thumbnail(for: attachment, notePath: nil)   // no clock advance

        XCTAssertNotNil(retried)
    }

    func testAtMostTheLimitOfLoadsRunAtOnce() async {
        AttachmentStubURLProtocol.reset { [png] _ in .data(png, delay: 0.1) }
        let loader = makeLoader(maxConcurrentLoads: 2)
        let attachments = (0..<6).map { image("/file/attachments/u/\($0).jpg") }

        await withTaskGroup(of: Void.self) { group in
            for attachment in attachments {
                group.addTask { _ = await loader.thumbnail(for: attachment, notePath: nil) }
            }
        }

        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 6)
        XCTAssertEqual(AttachmentStubURLProtocol.peakConcurrency, 2)
    }

    func testFilesNeverReachTheLoader() async {
        let loader = makeLoader()
        let file = NoteAttachment(target: "/file/attachments/u/a.pdf", name: "a.pdf", kind: .file)

        let result = await loader.thumbnail(for: file, notePath: nil)

        XCTAssertNil(result)
        XCTAssertNil(loader.cachedImage(for: file, notePath: nil))
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AttachmentThumbnailLoaderTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'AttachmentThumbnailLoader' in scope`.

- [ ] **Step 3: Implement**

Create `Quoote/Services/AttachmentThumbnailLoader.swift`:

```swift
import UIKit

/// Turns a `NoteAttachment` into a small picture for the history rows and the editor's attachment strip.
///
/// Loading is lazy and off the main thread: nothing is read until a tile appears, and a tile that scrolls away
/// cancels its load. Two caches sit in front: memory (about 32 MB, shared by every row) and, for pictures that
/// come from the Memos server, a size-capped folder on disk. Every failure is silent — the tile keeps its icon.
final class AttachmentThumbnailLoader: @unchecked Sendable {

    /// The longest edge of every thumbnail, in pixels.
    static let maxPixel = ThumbnailDownsampler.maxPixel

    /// How long a failure is remembered before the same picture is tried again.
    static let failureMemory: TimeInterval = 60

    static let shared = AttachmentThumbnailLoader(environment: .live)

    /// Everything the loader takes from the app, so a test can point it at a temp vault and a stub server.
    struct Environment {
        /// What reading one picture from the vault came to.
        enum VaultRead {
            /// The file is unchanged since the picture in memory was made.
            case unchanged(path: String)
            case image(path: String, CGImage, modifiedAt: Date)
            case notDownloaded
            case missing
        }

        /// Runs `body` with the vault open, or returns `nil` when no vault is connected.
        typealias VaultAccess = @Sendable (@Sendable (VaultFileStore) -> VaultRead) -> VaultRead?

        var session: URLSession
        var endpoint: @Sendable () -> String
        var token: @Sendable () -> String
        var allowInsecureHTTP: @Sendable () -> Bool
        var vaultAccess: VaultAccess
        var attachmentsFolder: @Sendable () -> String
        var diskCache: ThumbnailDiskCache
        var now: @Sendable () -> Date = { Date() }
        var maxConcurrentLoads = 4
        var maxFetchBytes = MemosAttachmentFetcher.defaultMaxBytes
    }

    private let environment: Environment
    private let fetcher: MemosAttachmentFetcher
    private let gate: AsyncGate
    private let memory = NSCache<NSString, MemoryEntry>()
    private let state = State()

    init(environment: Environment) {
        self.environment = environment
        fetcher = MemosAttachmentFetcher(
            session: environment.session,
            configuration: {
                .init(
                    endpoint: environment.endpoint(),
                    token: environment.token(),
                    allowInsecureHTTP: environment.allowInsecureHTTP()
                )
            },
            maxBytes: environment.maxFetchBytes
        )
        gate = AsyncGate(limit: environment.maxConcurrentLoads)
        memory.totalCostLimit = 32 * 1024 * 1024
        let diskCache = environment.diskCache
        Task.detached(priority: .utility) { diskCache.trim() }
    }

    // MARK: - API

    /// The picture if it is already in memory. No I/O, so a row's first render doesn't flash its placeholder.
    func cachedImage(for attachment: NoteAttachment, notePath: String?) -> UIImage? {
        guard attachment.kind == .image else { return nil }
        return memory.object(forKey: cacheKey(for: attachment, notePath: notePath) as NSString)?.image
    }

    /// The picture, at most `maxPixel` on its longest edge, or `nil`. Only images are loaded; a file tile is an
    /// icon. `notePath` is the vault-relative path of the note that holds the attachment, when it has one.
    func thumbnail(for attachment: NoteAttachment, notePath: String?) async -> UIImage? {
        guard attachment.kind == .image else { return nil }
        let key = cacheKey(for: attachment, notePath: notePath)
        let cached = memory.object(forKey: key as NSString)
        // The picture behind a URL never changes under it. A vault file can be replaced, so it is checked again.
        if attachment.isRemote, let cached { return cached.image }
        if await state.isFailing(key, now: environment.now()) { return cached?.image }

        let loaded = await state.coalesce(key: key) { [self] in
            if attachment.isRemote { return await loadRemote(attachment, key: key) }
            return await loadVault(attachment, notePath: notePath, key: key, cached: cached)
        }
        return loaded ?? cached?.image
    }

    // MARK: - Memos pictures

    private func loadRemote(_ attachment: NoteAttachment, key: String) async -> UIImage? {
        // The plain URL names the picture on disk; the thumbnail URL is only how it is asked for.
        guard let diskKey = fetcher.candidateURLs(for: attachment.target).last?.absoluteString else {
            return await fail(key)   // not ours to fetch: another host, or no endpoint or token
        }
        do { try await gate.acquire() } catch { return nil }

        let diskCache = environment.diskCache
        var picture = await offload {
            diskCache.data(forKey: diskKey).flatMap { ThumbnailDownsampler.downsample(data: $0) }
        }
        if picture == nil, !Task.isCancelled {
            picture = await fetcher.image(for: attachment.target, maxPixel: Self.maxPixel)
            if let fetched = picture {
                await offload {
                    if let jpeg = ThumbnailDownsampler.jpegData(from: fetched) { diskCache.store(jpeg, forKey: diskKey) }
                }
            }
        }
        await gate.release()

        guard let picture else { return await fail(key) }
        let image = UIImage(cgImage: picture)
        remember(image, key: key, stamp: nil)
        await state.clearFailure(key)
        return image
    }

    // MARK: - Vault pictures

    private func loadVault(
        _ attachment: NoteAttachment, notePath: String?, key: String, cached: MemoryEntry?
    ) async -> UIImage? {
        do { try await gate.acquire() } catch { return nil }

        let known = await state.resolution(for: key)
        let folder = environment.attachmentsFolder()
        let target = attachment.target
        let cachedStamp = cached?.stamp
        let read = await offload { [vaultAccess = environment.vaultAccess] () -> Environment.VaultRead? in
            vaultAccess { store in
                // A path found before is trusted until the file disappears; then the search starts over.
                let remembered = known.flatMap { store.attachmentModificationDate(at: $0) != nil ? $0 : nil }
                guard let path = remembered
                    ?? store.locateAttachment(target, attachmentsFolder: folder, notePath: notePath)
                else { return .missing }

                if let stamp = store.attachmentModificationDate(at: path), stamp == cachedStamp {
                    return .unchanged(path: path)
                }
                switch store.attachmentThumbnail(at: path, maxPixel: AttachmentThumbnailLoader.maxPixel) {
                case .image(let picture, let modifiedAt): return .image(path: path, picture, modifiedAt: modifiedAt)
                case .notDownloaded: return .notDownloaded
                case .unreadable: return .missing
                }
            }
        }
        await gate.release()

        switch read {
        case .unchanged(let path)?:
            await state.setResolution(path, for: key)
            await state.clearFailure(key)
            return cached?.image
        case .image(let path, let picture, let modifiedAt)?:
            let image = UIImage(cgImage: picture)
            remember(image, key: key, stamp: modifiedAt)
            await state.setResolution(path, for: key)
            await state.clearFailure(key)
            return image
        case .notDownloaded?:
            return await fail(key)   // a download was requested; the next try, a minute on, may find the file
        case .missing?, nil:
            await state.forgetResolution(for: key)
            return await fail(key)
        }
    }

    // MARK: - Helpers

    private func cacheKey(for attachment: NoteAttachment, notePath: String?) -> String {
        if attachment.isRemote { return "r|\(environment.endpoint())|\(attachment.target)" }
        let noteFolder = notePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        return "v|\(environment.attachmentsFolder())|\(noteFolder)|\(attachment.target)"
    }

    private func remember(_ image: UIImage, key: String, stamp: Date?) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        memory.setObject(MemoryEntry(image: image, stamp: stamp), forKey: key as NSString, cost: cost)
    }

    /// Remembers the failure — unless the load was only cancelled — and returns `nil`.
    private func fail(_ key: String) async -> UIImage? {
        if !Task.isCancelled { await state.recordFailure(key, at: environment.now()) }
        return nil
    }

    /// Runs blocking work (file reads, decoding) on a background queue, not on the cooperative thread pool.
    private func offload<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    private final class MemoryEntry: @unchecked Sendable {
        let image: UIImage
        /// The vault file's modification date when the picture was made; `nil` for a Memos picture.
        let stamp: Date?

        init(image: UIImage, stamp: Date?) {
            self.image = image
            self.stamp = stamp
        }
    }

    /// What changes while pictures load: who is waiting on what, what failed lately, where vault files were found.
    private actor State {
        private final class Flight {
            let id = UUID()
            var task: Task<UIImage?, Never>?
            var waiters = 0
        }

        private var flights: [String: Flight] = [:]
        private var failures: [String: Date] = [:]
        private var resolutions: [String: String] = [:]

        /// Runs `work` once for every caller asking for `key` at the same time. The work is cancelled when the
        /// last caller still waiting for it goes away.
        func coalesce(key: String, work: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
            let flight: Flight
            if let existing = flights[key] {
                flight = existing
            } else {
                flight = Flight()
                flights[key] = flight
                let id = flight.id
                flight.task = Task(priority: .utility) { [weak self] in
                    let result = await work()
                    await self?.finish(key: key, id: id)
                    return result
                }
            }
            flight.waiters += 1
            let id = flight.id
            let task = flight.task!
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { await self.waiterLeft(key: key, id: id) }
            }
        }

        private func finish(key: String, id: UUID) {
            if flights[key]?.id == id { flights[key] = nil }
        }

        private func waiterLeft(key: String, id: UUID) {
            guard let flight = flights[key], flight.id == id else { return }
            flight.waiters -= 1
            guard flight.waiters <= 0 else { return }
            // Unregistered at once, so a caller arriving now starts a fresh load instead of joining a cancelled one.
            flights[key] = nil
            flight.task?.cancel()
        }

        func isFailing(_ key: String, now: Date) -> Bool {
            guard let failedAt = failures[key] else { return false }
            return now.timeIntervalSince(failedAt) < AttachmentThumbnailLoader.failureMemory
        }

        func recordFailure(_ key: String, at date: Date) { failures[key] = date }
        func clearFailure(_ key: String) { failures[key] = nil }

        func resolution(for key: String) -> String? { resolutions[key] }
        func setResolution(_ path: String, for key: String) { resolutions[key] = path }
        func forgetResolution(for key: String) { resolutions[key] = nil }
    }
}

extension AttachmentThumbnailLoader.Environment {
    /// The app's own settings, Keychain token, connected vault and cache folder.
    static var live: Self {
        // The loader keeps its own disk cache, and the server marks private attachments `no-store` anyway.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        return Self(
            session: URLSession(configuration: configuration),
            endpoint: { AppSettings.endpointBaseURL },
            token: { KeychainTokenStore.getToken() },
            allowInsecureHTTP: { AppSettings.allowInsecureHTTP },
            vaultAccess: { body in
                try? VaultBookmarkStore.withAccess { root in body(VaultFileStore(root: root)) }
            },
            attachmentsFolder: { AppSettings.vaultAttachmentsFolder },
            diskCache: ThumbnailDiskCache(directory: ThumbnailDiskCache.defaultDirectory)
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AttachmentThumbnailLoaderTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 16 tests, with 0 failures` and `** TEST SUCCEEDED **`. Two tests that read a vault file for the first time in the process can take several seconds each (the simulator's file-coordination service starting up); that is expected.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Services/AttachmentThumbnailLoader.swift QuooteTests/AttachmentThumbnailLoaderTests.swift \
        Quoote.xcodeproj/project.pbxproj
git commit -m "feat: AttachmentThumbnailLoader, lazy cached cancellable thumbnails for vault and Memos pictures"
```

---

### Task 12: `AttachmentTile` — what a tile looks like

The 56 pt square: the picture for an image (an icon until it arrives, then a crossfade), a type icon and extension for a file, an optional "+N" badge. Display only.

**Files:**
- Create: `Quoote/Views/Components/AttachmentTile.swift`
- Test: `QuooteTests/AttachmentFileIconTests.swift`, `QuooteTests/AttachmentTileLayoutTests.swift`

**Interfaces:**
- Consumes: `NoteAttachment` (Task 1); `AttachmentThumbnailLoader.shared`, `cachedImage(for:notePath:)`, `thumbnail(for:notePath:)` (Task 11).
- Produces: `enum AttachmentFileIcon` — `static func symbol(forFilename:) -> String`, `static func label(forFilename:) -> String`; `struct AttachmentTile: View` — `static let size: CGFloat` (56); `init(attachment: NoteAttachment, notePath: String? = nil, extra: Int = 0, loader: AttachmentThumbnailLoader = .shared)`.

- [ ] **Step 1: Write the failing tests**

Create `QuooteTests/AttachmentFileIconTests.swift`:

```swift
import XCTest
@testable import Quoote

final class AttachmentFileIconTests: XCTestCase {

    func testTheSymbolFollowsTheFileType() {
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "Report.pdf"), "doc.richtext")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "song.mp3"), "waveform")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "clip.mov"), "film")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "bundle.zip"), "doc.zipper")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "notes.txt"), "doc.text")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "logo.svg"), "photo")
    }

    func testAnUnknownOrMissingExtensionIsAGenericDocument() {
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "mystery.zzzzz"), "doc")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "README"), "doc")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: ""), "doc")
    }

    func testTheLabelIsTheUppercasedExtensionAtMostFourLong() {
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "Report.pdf"), "PDF")
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "archive.tar.gz"), "GZ")
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "book.markdown"), "MARK")
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "README"), "")
    }
}
```

Create `QuooteTests/AttachmentTileLayoutTests.swift` (renders the view with `ImageRenderer`, so the tile's size is pinned without a UI test):

```swift
import XCTest
import SwiftUI
@testable import Quoote

@MainActor
final class AttachmentTileLayoutTests: XCTestCase {

    private func renderedSize<V: View>(_ view: V) -> CGSize? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size
    }

    func testAFileTileIsFiftySixPointsSquare() {
        let file = NoteAttachment(target: "/file/attachments/u/a.pdf", name: "a.pdf", kind: .file)
        XCTAssertEqual(renderedSize(AttachmentTile(attachment: file)), CGSize(width: 56, height: 56))
    }

    func testAnImageTileIsFiftySixPointsSquareBeforeItsPictureArrives() {
        let image = NoteAttachment(target: "/file/attachments/u/a.jpg", name: "a.jpg", kind: .image)
        XCTAssertEqual(renderedSize(AttachmentTile(attachment: image)), CGSize(width: 56, height: 56))
    }

    func testTheExtraBadgeDoesNotChangeTheTileSize() {
        let file = NoteAttachment(target: "/file/attachments/u/a.pdf", name: "a.pdf", kind: .file)
        XCTAssertEqual(renderedSize(AttachmentTile(attachment: file, extra: 12)), CGSize(width: 56, height: 56))
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AttachmentFileIconTests -only-testing:QuooteTests/AttachmentTileLayoutTests \
  2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'AttachmentFileIcon' in scope` / `cannot find 'AttachmentTile' in scope`.

- [ ] **Step 3: Implement**

Create `Quoote/Views/Components/AttachmentTile.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// The SF Symbol and the label a file tile shows for a filename's type.
enum AttachmentFileIcon {

    static func symbol(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    /// The uppercased extension (`PDF`), or an empty string when there is none.
    static func label(forFilename filename: String) -> String {
        String((filename as NSString).pathExtension.uppercased().prefix(4))
    }
}

/// A 56 pt square standing for one attachment: the picture for an image, a type icon and extension for a file.
/// Display only — it takes no taps of its own.
struct AttachmentTile: View {
    static let size: CGFloat = 56
    private static let corner: CGFloat = 8

    let attachment: NoteAttachment
    /// The vault-relative path of the note holding the attachment, when it has one: `![[a.png]]` may name a file
    /// that sits beside the note.
    var notePath: String? = nil
    /// How many more attachments the note holds, shown as "+N".
    var extra: Int = 0
    var loader: AttachmentThumbnailLoader = .shared

    @State private var image: UIImage?

    init(
        attachment: NoteAttachment,
        notePath: String? = nil,
        extra: Int = 0,
        loader: AttachmentThumbnailLoader = .shared
    ) {
        self.attachment = attachment
        self.notePath = notePath
        self.extra = extra
        self.loader = loader
        // Seeded from memory, so a picture seen before is there on the first frame instead of flashing an icon.
        _image = State(initialValue: loader.cachedImage(for: attachment, notePath: notePath))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.corner)
                .fill(Color(uiColor: .secondarySystemFill))
            content
        }
        .frame(width: Self.size, height: Self.size)
        .overlay(alignment: .bottomTrailing) {
            if extra > 0 { badge }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: "\(attachment.identity)|\(notePath ?? "")") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch attachment.kind {
        case .image:
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.size, height: Self.size)
                    .clipShape(RoundedRectangle(cornerRadius: Self.corner))
                    .transition(.opacity)
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        case .file:
            VStack(spacing: 2) {
                Image(systemName: AttachmentFileIcon.symbol(forFilename: attachment.name))
                    .font(.title3)
                Text(AttachmentFileIcon.label(forFilename: attachment.name))
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var badge: some View {
        Text("+\(extra)")
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(3)
    }

    private var accessibilityText: String {
        let base = attachment.kind == .image ? "Image attachment" : "File: \(attachment.name)"
        return extra > 0 ? "\(base), and \(extra) more" : base
    }

    private func load() async {
        guard attachment.kind == .image else { return }
        // A recycled row can arrive still holding the previous attachment's picture.
        image = loader.cachedImage(for: attachment, notePath: notePath)
        guard let loaded = await loader.thumbnail(for: attachment, notePath: notePath), loaded !== image else { return }
        withAnimation(.easeIn(duration: 0.15)) { image = loaded }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AttachmentFileIconTests -only-testing:QuooteTests/AttachmentTileLayoutTests \
  2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 6 tests, with 0 failures` (3 + 3) and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Views/Components/AttachmentTile.swift QuooteTests/AttachmentFileIconTests.swift \
        QuooteTests/AttachmentTileLayoutTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: AttachmentTile, a 56 pt picture or file tile"
```


---

### Task 13: History rows show the tile

The row becomes `[text column] [tile]`: the text narrows beside a 56 pt tile at the trailing edge, centred vertically. A note with nothing attached renders exactly as before.

**Files:**
- Modify: `Quoote/Views/Components/NoteRowView.swift`
- Test: `QuooteTests/NoteRowViewLayoutTests.swift`

**Interfaces:**
- Consumes: `UnifiedNote.attachments`, `UnifiedNote.vaultPath` (Task 5); `NoteAttachments.tile(from:)` (Task 1); `AttachmentTile` (Task 12).
- Produces: `NoteRowView` shows an `AttachmentTile` for the note's first picture (else its first file), with "+N" for the rest.

- [ ] **Step 1: Write the failing tests**

Create `QuooteTests/NoteRowViewLayoutTests.swift` (renders the row with `ImageRenderer`: a plain row is shorter than a tile, a row with an attachment grows to hold one, and a note not scanned yet renders like one with nothing attached):

```swift
import XCTest
import SwiftUI
@testable import Quoote

@MainActor
final class NoteRowViewLayoutTests: XCTestCase {

    private func row(attachments: [NoteAttachment]?) -> NoteRowView {
        let entry = VaultIndexEntry(
            relativePath: "a.md", title: "Hello", preview: "Hello there", tags: [],
            modifiedAt: Date(), fileSize: 1, attachments: attachments
        )
        return NoteRowView(note: .vault(entry))
    }

    private func height(of view: NoteRowView) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 320))
        renderer.scale = 1
        return renderer.uiImage?.size.height ?? 0
    }

    func testARowWithoutAttachmentsIsShorterThanTheTile() {
        XCTAssertLessThan(height(of: row(attachments: [])), AttachmentTile.size)
    }

    func testARowWithAnAttachmentGrowsToHoldTheTile() {
        let file = NoteAttachment(target: "Report.pdf", name: "Report.pdf", kind: .file)
        XCTAssertGreaterThanOrEqual(height(of: row(attachments: [file])), AttachmentTile.size)
    }

    func testANoteNotScannedYetRendersLikeOneWithNothingAttached() {
        XCTAssertEqual(height(of: row(attachments: nil)), height(of: row(attachments: [])))
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/NoteRowViewLayoutTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: 1 failure — `testARowWithAnAttachmentGrowsToHoldTheTile` (no tile yet, so the row is shorter than 56 pt) — and `** TEST FAILED **`.

- [ ] **Step 3: Implement**

In `Quoote/Views/Components/NoteRowView.swift`, replace:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.excerpt)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)

            // One Text so date and tags truncate together on a single line.
            Text("\(Text(dateString).foregroundStyle(.secondary))\(tagsText)")
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
```

with:

```swift
    var body: some View {
        let tile = NoteAttachments.tile(from: note.attachments)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.excerpt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.tail)

                // One Text so date and tags truncate together on a single line.
                Text("\(Text(dateString).foregroundStyle(.secondary))\(tagsText)")
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let tile {
                AttachmentTile(attachment: tile.attachment, notePath: note.vaultPath, extra: tile.extra)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
```


- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/NoteRowViewLayoutTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 3 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Quoote/Views/Components/NoteRowView.swift QuooteTests/NoteRowViewLayoutTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: history rows show a tile for the note's attachments"
```

---

### Task 14: The editor's attachment strip shows what the note already holds

`NoteEditorView`'s pending-attachments bar becomes `AttachmentBar` (extracted — the view is 984 lines). It now leads with the note's existing attachments, read-only, then the pending ones as before. Existing attachments are re-found as the text changes (debounced 300 ms), so deleting a line removes its tile; for a Memos note they also include what the server lists on the memo. The strip shows when either list is non-empty, and the editor's bottom padding follows.

**Files:**
- Create: `Quoote/Views/Components/AttachmentBar.swift`
- Modify: `Quoote/Views/NoteEditorView.swift`
- Test: `QuooteTests/AttachmentBarLayoutTests.swift`

**Interfaces:**
- Consumes: `AttachmentTile`, `AttachmentFileIcon` (Task 12); `NoteAttachments.parse/merged` (Task 1); `ServerMemoSummary.attachments` via `ServerMemosStore.memo(memoID:)` (Task 4); the existing `PendingImage`, `PendingFile`.
- Produces: `struct AttachmentBar: View` — `static let height: CGFloat` (72); `init(existing: [NoteAttachment], notePath: String? = nil, pendingImages: Binding<[PendingImage]>, pendingFiles: Binding<[PendingFile]>)`. `NoteEditorView` gains `existingAttachments`, `showsAttachmentBar`, `vaultNotePath`, `currentAttachments()`, `scheduleAttachmentScan(immediately:)`. `isBlank` still looks only at pending attachments: an existing attachment can't be in a note with no text.

- [ ] **Step 1: Write the failing test**

Create `QuooteTests/AttachmentBarLayoutTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Quoote

@MainActor
final class AttachmentBarLayoutTests: XCTestCase {

    private func height(of bar: AttachmentBar) -> CGFloat {
        let renderer = ImageRenderer(content: bar.frame(width: 390))
        renderer.scale = 1
        return renderer.uiImage?.size.height ?? 0
    }

    func testTheStripIsSeventyTwoPointsTallWithAnExistingFile() {
        let file = NoteAttachment(target: "Report.pdf", name: "Report.pdf", kind: .file)
        let bar = AttachmentBar(existing: [file], pendingImages: .constant([]), pendingFiles: .constant([]))
        XCTAssertEqual(height(of: bar), AttachmentBar.height)
    }

    func testTheStripKeepsItsHeightWithExistingPicturesAndPendingFiles() {
        let photo = NoteAttachment(target: "trip.jpg", name: "trip.jpg", kind: .image)
        var pending = PendingFile(filename: "Notes.txt")
        pending.isUploading = false
        let bar = AttachmentBar(existing: [photo], pendingImages: .constant([]), pendingFiles: .constant([pending]))
        XCTAssertEqual(height(of: bar), AttachmentBar.height)
    }
}
```

- [ ] **Step 2: Run the test to see it fail**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AttachmentBarLayoutTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: the build fails with `cannot find 'AttachmentBar' in scope`.

- [ ] **Step 3: Create the strip**

Create `Quoote/Views/Components/AttachmentBar.swift` — the pending-image and pending-file views are the ones that lived in `NoteEditorView.pendingAttachmentsBar`, moved as they were; files now use one `FileChip` (type icon and name):

```swift
import SwiftUI

/// The strip above the editor bar: what the note already holds (read-only), then what is waiting to be sent
/// (with ✕, or a spinner while it uploads). Existing attachments go away by deleting their line in the text.
struct AttachmentBar: View {
    static let height: CGFloat = 72

    let existing: [NoteAttachment]
    /// The vault-relative path of the open note, when it is a vault note.
    var notePath: String? = nil
    @Binding var pendingImages: [PendingImage]
    @Binding var pendingFiles: [PendingFile]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(existing, id: \.identity) { attachment in
                    switch attachment.kind {
                    case .image:
                        AttachmentTile(attachment: attachment, notePath: notePath)
                    case .file:
                        FileChip(name: attachment.name)
                    }
                }
                ForEach(pendingImages) { p in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: p.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if p.isUploading {
                            ProgressView()
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingImages.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                ForEach(pendingFiles) { f in
                    ZStack(alignment: .topTrailing) {
                        FileChip(name: f.filename)
                        if f.isUploading {
                            ProgressView()
                                .frame(height: 56)
                                .frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingFiles.removeAll { $0.id == f.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(height: Self.height)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
    }
}

/// A file as a chip: its type icon and its name, two lines at most.
private struct FileChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: AttachmentFileIcon.symbol(forFilename: name))
                .font(.caption)
            Text(name)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: 80)
        }
        .padding(8)
        .frame(height: 56)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 4: Wire it into the editor**

State, next to the other attachment state:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var uploadError: String?
```

with:

```swift
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var uploadError: String?
    /// What the note already holds: pictures and files embedded in its text and, for a Memos note, those the
    /// server lists on the memo. Shown read-only at the front of the attachment strip.
    @State private var existingAttachments: [NoteAttachment] = []
    @State private var attachmentScanTask: Task<Void, Never>?
```


The strip in the bottom overlay:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
                if hasPendingAttachments {
                    pendingAttachmentsBar
                }
```

with:

```swift
                if showsAttachmentBar {
                    AttachmentBar(
                        existing: existingAttachments,
                        notePath: vaultNotePath,
                        pendingImages: $pendingImages,
                        pendingFiles: $pendingFiles
                    )
                }
```


Rescan when the text changes:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
        .onChange(of: draftText) { _, _ in
            schedulePersist()
            // Editing after a send re-arms auto-commit so leaving captures the new text.
            if draftText != lastSentText { didTapDone = false }
        }
        .onChange(of: serverMemoContent) { _, _ in
            stageServerMemoContent()
            if serverMemoContent != lastSentText { didTapDone = false }
        }
        .onChange(of: vaultNoteBody) { _, _ in
            scheduleVaultSave()
        }
```

with:

```swift
        .onChange(of: draftText) { _, _ in
            schedulePersist()
            scheduleAttachmentScan()
            // Editing after a send re-arms auto-commit so leaving captures the new text.
            if draftText != lastSentText { didTapDone = false }
        }
        .onChange(of: serverMemoContent) { _, _ in
            stageServerMemoContent()
            scheduleAttachmentScan()
            if serverMemoContent != lastSentText { didTapDone = false }
        }
        .onChange(of: vaultNoteBody) { _, _ in
            scheduleVaultSave()
            scheduleAttachmentScan()
        }
```


Stop a pending scan when the editor goes away:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
            cleanupBlankDraft()
            remoteTagTask?.cancel()
        }
```

with:

```swift
            cleanupBlankDraft()
            remoteTagTask?.cancel()
            attachmentScanTask?.cancel()
        }
```


The text keeps clear of the strip:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
            extraBottomPadding: Self.editorBarHeight + 16
                + (hasPendingAttachments ? Self.attachmentsBarHeight : 0),
```

with:

```swift
            extraBottomPadding: Self.editorBarHeight + 16
                + (showsAttachmentBar ? AttachmentBar.height : 0),
```


The old bar moves out into `AttachmentBar`; what the editor keeps is when to show it and which vault note it is:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(pendingImages) { p in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: p.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if p.isUploading {
                            ProgressView()
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingImages.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                ForEach(pendingFiles) { f in
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                            Text(f.filename)
                                .font(.caption)
                                .lineLimit(2)
                                .frame(maxWidth: 80)
                        }
                        .padding(8)
                        .frame(height: 56)
                        .background(Color(uiColor: .secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 8))
                        if f.isUploading {
                            ProgressView()
                                .frame(height: 56)
                                .frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Button { pendingFiles.removeAll { $0.id == f.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black)
                                    .font(.caption)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(height: Self.attachmentsBarHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
    }

    private static let attachmentsBarHeight: CGFloat = 72
```

with:

```swift
    /// The strip shows when the note already holds attachments or some are waiting to be sent.
    private var showsAttachmentBar: Bool {
        !existingAttachments.isEmpty || hasPendingAttachments
    }

    /// The open note's vault-relative path, when it is a vault note: `![[a.png]]` may name a file beside it.
    private var vaultNotePath: String? {
        if case .vaultFile(let path) = target { return path }
        return nil
    }
```


Finding the attachments, ahead of the upload section:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
    // MARK: Attachment upload
```

with:

```swift
    // MARK: Existing attachments

    /// What the note already holds: attachments embedded in its text, plus — for a Memos note — those the
    /// server keeps on the memo itself.
    private func currentAttachments() -> [NoteAttachment] {
        let embedded = NoteAttachments.parse(textBinding.wrappedValue)
        guard case .serverMemo(let memoID) = target else { return embedded }
        return NoteAttachments.merged(embedded, serverMemosStore.memo(memoID: memoID)?.attachments ?? [])
    }

    /// Rescans for attachments. Debounced so typing doesn't run the parser on every keystroke;
    /// `immediately` is for opening a note, which should show its strip at once.
    private func scheduleAttachmentScan(immediately: Bool = false) {
        attachmentScanTask?.cancel()
        attachmentScanTask = Task { @MainActor in
            if !immediately { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let found = currentAttachments()
            if found != existingAttachments { existingAttachments = found }
        }
    }

    // MARK: Attachment upload
```


Scan once the note has loaded:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
        if serverMemoError == nil, vaultLoadError == nil { focusEditor() }
        fetchRemoteTagsOnce()
        refreshTagSuggestions()
    }
```

with:

```swift
        if serverMemoError == nil, vaultLoadError == nil { focusEditor() }
        fetchRemoteTagsOnce()
        refreshTagSuggestions()
        scheduleAttachmentScan(immediately: true)
    }
```


A fresh capture note starts without a strip:

In `Quoote/Views/NoteEditorView.swift`, replace:

```swift
        pendingImages = []
        pendingFiles = []
        focusEditor()
    }
```

with:

```swift
        pendingImages = []
        pendingFiles = []
        existingAttachments = []
        focusEditor()
    }
```


- [ ] **Step 5: Run the test**

```bash
xcodegen generate
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuooteTests/AttachmentBarLayoutTests 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 2 tests, with 0 failures` and `** TEST SUCCEEDED **`. The editor itself has no unit test (it is a UIKit text view inside SwiftData-backed state); its behaviour is on the device checklist in Task 15. This build compiling is the check that the wiring is sound.

- [ ] **Step 6: Commit**

```bash
git add Quoote/Views/Components/AttachmentBar.swift Quoote/Views/NoteEditorView.swift \
        QuooteTests/AttachmentBarLayoutTests.swift Quoote.xcodeproj/project.pbxproj
git commit -m "feat: the editor's attachment strip shows what the note already holds"
```

---

### Task 15: Whole-suite run, and what only a device can check

**Files:** none changed, except the spec's status line.

- [ ] **Step 1: The project file is in step with the sources**

```bash
xcodegen generate
git status --short
```

Expected: no output (nothing modified or untracked). A modified `project.pbxproj` here means a file was added without committing the regenerated project: commit it.

- [ ] **Step 2: Run the whole suite**

```bash
xcodebuild test -project Quoote.xcodeproj -scheme Quoote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E ": error: |Executed|\*\* TEST"
```

Expected: `Executed 374 tests, with 0 failures` (the 224 from before plus 150 new) and `** TEST SUCCEEDED **`. Any failure in an old test is a regression from this work: fix it, don't skip it.

- [ ] **Step 3: Read the whole branch diff once**

```bash
git diff main --stat
git diff main -- Quoote/Views/NoteEditorView.swift
```

Expected: the stat lists only the files named in this plan's File Structure, plus the new tests and `project.pbxproj`. In the editor diff, check that nothing was removed beyond `pendingAttachmentsBar` and `attachmentsBarHeight`.

- [ ] **Step 4: Mark the spec as built**

In `docs/superpowers/specs/2026-10-03-attachment-thumbnails-design.md` change the `**Status:**` line from `Awaiting review` to `Implemented — device checklist pending`, then:

```bash
git add docs/superpowers/specs/2026-10-03-attachment-thumbnails-design.md
git commit -m "docs: attachment thumbnails spec — implemented"
```

- [ ] **Step 5: Hand the device checklist to the user**

The simulator can't reach iCloud and there is no tap automation here, so these need a person with the app on a phone. Report them as *not yet verified*, not as passing:

1. **Vault, normal:** a note with `![[photo.jpg]]` shows the photo on its history row, and as a tile in the strip when opened. A note with only an image has no raw `![[…]]` text on its row.
2. **Vault, iCloud-evicted image:** evict an image in Files, open the history: the tile stays on the photo icon and the app doesn't freeze; after iCloud downloads the file, scroll the row away and back (or wait a minute): the picture appears.
3. **Memos, normal:** a note whose text links an image shows it; a picture attached to a memo in the Memos web app (not in its text) shows too.
4. **Memos, private memo:** a picture on a *private* memo shows — that proves the token is sent.
5. **Memos, offline:** view some Memos pictures, then enable airplane mode and relaunch: the ones already seen still show.
6. **Files:** a note with a PDF link shows a PDF icon with "PDF"; a note that is only that link shows the file's name as its row text; "+N" appears when there are more attachments.
7. **Scrolling:** a history of a few hundred rows scrolls smoothly, and picture tiles fill in without hitching.
8. **A large HEIC** (a 12 MP photo) in a vault note shows without a memory spike.
9. **Dark mode and VoiceOver:** tiles look right in dark mode; VoiceOver reads "Image attachment" / "File: name", plus "and N more".
10. **First launch after updating:** the history shows at once from the old index; tiles appear a moment later as the background re-read finishes.
