import XCTest
@testable import Quoote

final class UnifiedNoteVaultTests: XCTestCase {

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

    func testVaultNoteExposesTitleDateAndTags() {
        let note = UnifiedNote.vault(entry("a.md", title: "Hello", modified: 500, tags: ["inbox"]))
        XCTAssertEqual(note.title, "Hello")
        XCTAssertEqual(note.date, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(note.tags, ["inbox"])
        XCTAssertEqual(note.id, "v-a.md")
    }

    func testVaultNoteEditorTargetIsVaultFile() {
        let note = UnifiedNote.vault(entry("folder/a.md", title: "Hello", modified: 500))
        XCTAssertEqual(note.editorTarget, .vaultFile("folder/a.md"))
    }

    func testMergeSortsVaultEntriesNewestFirst() {
        let notes = UnifiedNote.merge(
            vaultEntries: [
                entry("old.md", title: "Old", modified: 100),
                entry("new.md", title: "New", modified: 900)
            ],
            drafts: []
        )
        XCTAssertEqual(notes.map(\.title), ["New", "Old"])
    }

    func testMergeIncludesUnsentLocalDrafts() {
        let draft = Draft(text: "Unsent local note")
        let notes = UnifiedNote.merge(
            vaultEntries: [entry("a.md", title: "Filed", modified: 100)],
            drafts: [draft]
        )
        XCTAssertEqual(Set(notes.map(\.title)), ["Filed", "Unsent local note"])
    }

    func testMergeExcludesBlankAndArchivedDrafts() {
        let blank = Draft(text: "   ")
        let archived = Draft(text: "Already filed")
        archived.isArchived = true

        let notes = UnifiedNote.merge(vaultEntries: [], drafts: [blank, archived])
        XCTAssertTrue(notes.isEmpty)
    }

    func testMergeExcludesTheDraftBeingComposed() {
        let composing = Draft(text: "Still typing")
        let notes = UnifiedNote.merge(vaultEntries: [], drafts: [composing], excludeDraftID: composing.id)
        XCTAssertTrue(notes.isEmpty)
    }

    /// Switching destinations migrates nothing: a draft still in flight to
    /// the Memos queue must not show up as a vault-sendable draft.
    func testMergeExcludesPendingMemosDraft() {
        let pending = Draft(text: "Sending to Memos")
        pending.sendState = .pending
        let notes = UnifiedNote.merge(vaultEntries: [], drafts: [pending])
        XCTAssertTrue(notes.isEmpty)
    }

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
