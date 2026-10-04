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
