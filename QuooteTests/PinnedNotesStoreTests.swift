import XCTest
@testable import Quoote

final class PinnedNotesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PinnedNotesStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testOnlyOneNoteIsPinned() {
        let store = PinnedNotesStore(defaults: defaults)
        store.pin("m-1")
        store.pin("m-2")
        XCTAssertFalse(store.isPinned("m-1"))
        XCTAssertTrue(store.isPinned("m-2"))
        store.toggle("m-2")
        XCTAssertNil(store.pinnedID)
    }

    func testPinPersists() {
        PinnedNotesStore(defaults: defaults).pin("v-Notes/a b.md")
        XCTAssertEqual(PinnedNotesStore(defaults: defaults).target, .vaultFile("Notes/a b.md"))
    }

    func testTargetRoundTrips() throws {
        let draftID = UUID()
        let targets: [NoteEditorTarget] = [.localDraft(draftID), .serverMemo("abc-1"), .vaultFile("x/y-z.md")]
        for target in targets {
            let id = try XCTUnwrap(PinnedNotesStore.id(for: target))
            XCTAssertEqual(PinnedNotesStore.target(for: id), target)
        }
        XCTAssertNil(PinnedNotesStore.id(for: .newNote))
        XCTAssertNil(PinnedNotesStore.target(for: "d-not-a-uuid"))
        XCTAssertNil(PinnedNotesStore.target(for: "q-1"))
    }

    func testPinFollowsTheDraftItWasSentAs() {
        let store = PinnedNotesStore(defaults: defaults)
        let draftID = UUID()
        store.pin("d-\(draftID.uuidString)")
        store.migrate(fromDraft: UUID(), to: "m-other")
        XCTAssertEqual(store.target, .localDraft(draftID))
        store.migrate(fromDraft: draftID, to: "m-42")
        XCTAssertEqual(store.target, .serverMemo("42"))
    }
}
