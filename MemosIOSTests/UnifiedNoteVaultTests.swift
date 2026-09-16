import XCTest
@testable import MemoChat

final class UnifiedNoteVaultTests: XCTestCase {

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
}
