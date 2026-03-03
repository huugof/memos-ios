import XCTest
import SwiftData
@testable import Memos

@MainActor
final class DraftBehaviorTests: XCTestCase {
    private var container: ModelContainer!
    private var modelContext: ModelContext!
    private var originalSettings: AppSettingsSnapshot!

    override func setUpWithError() throws {
        try super.setUpWithError()

        originalSettings = AppSettingsSnapshot.capture()
        resetSettingsForTests()

        let schema = Schema([Draft.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        modelContext = container.mainContext
    }

    override func tearDownWithError() throws {
        originalSettings.restore()
        originalSettings = nil
        modelContext = nil
        container = nil
        try super.tearDownWithError()
    }

    func testPreferredDraftCollapsesDuplicateTransientBlanks() throws {
        _ = DraftStore.createDraft(in: modelContext)
        _ = DraftStore.createDraft(in: modelContext)

        let preferred = DraftResumeCoordinator.preferredDraft(from: try allDrafts(), in: modelContext, now: Date())
        let blanks = try allDrafts().filter(\.isTransientBlankUnsent)

        XCTAssertTrue(preferred.isTransientBlankUnsent)
        XCTAssertEqual(blanks.count, 1)
    }

    func testDeleteTransientBlankIfNeededDeletesOnlyBlankDrafts() throws {
        let blank = DraftStore.createDraft(in: modelContext)
        let started = DraftStore.createDraft(in: modelContext, text: "Started note")

        let deletedBlank = DraftStore.deleteTransientBlankIfNeeded(blank, in: modelContext)
        let deletedStarted = DraftStore.deleteTransientBlankIfNeeded(started, in: modelContext)
        let remainingIDs = try Set(allDrafts().map(\.id))

        XCTAssertTrue(deletedBlank)
        XCTAssertFalse(deletedStarted)
        XCTAssertFalse(remainingIDs.contains(blank.id))
        XCTAssertTrue(remainingIDs.contains(started.id))
    }

    func testDeleteClearsLastActiveDraftID() throws {
        let draft = DraftStore.createDraft(in: modelContext, text: "To delete")
        DraftResumeCoordinator.markActiveDraft(draft)

        DraftStore.delete(draft, in: modelContext)

        XCTAssertNil(AppSettings.lastActiveDraftID)
        XCTAssertTrue(try allDrafts().isEmpty)
    }

    func testPreferredDraftResumesLastActiveWhenDelayWindowIsOpen() throws {
        let draft = DraftStore.createDraft(in: modelContext, text: "Continue this")
        DraftResumeCoordinator.markActiveDraft(draft)
        AppSettings.newNoteDelay = .seconds30
        AppSettings.resumeDeadlineAt = Date().addingTimeInterval(30)

        let preferred = DraftResumeCoordinator.preferredDraft(from: try allDrafts(), in: modelContext, now: Date())

        XCTAssertEqual(preferred.id, draft.id)
    }

    func testPreferredDraftCreatesFreshBlankWhenImmediate() throws {
        let old = DraftStore.createDraft(in: modelContext, text: "Old note")
        DraftResumeCoordinator.markActiveDraft(old)
        AppSettings.newNoteDelay = .immediately
        AppSettings.resumeDeadlineAt = Date().addingTimeInterval(30)

        let preferred = DraftResumeCoordinator.preferredDraft(from: try allDrafts(), in: modelContext, now: Date())

        XCTAssertNotEqual(preferred.id, old.id)
        XCTAssertTrue(preferred.isBlank)
    }

    private func allDrafts() throws -> [Draft] {
        try modelContext.fetch(FetchDescriptor<Draft>())
    }

    private func resetSettingsForTests() {
        AppSettings.endpointBaseURL = ""
        AppSettings.allowInsecureHTTP = false
        AppSettings.keepTextAfterSend = true
        AppSettings.markSentOnSuccess = true
        AppSettings.clearErrorOnEdit = true
        AppSettings.newNoteDelay = .immediately
        AppSettings.lastBackgroundAt = nil
        AppSettings.lastActiveDraftID = nil
        AppSettings.resumeDeadlineAt = nil
    }
}

private struct AppSettingsSnapshot {
    let endpointBaseURL: String
    let allowInsecureHTTP: Bool
    let keepTextAfterSend: Bool
    let markSentOnSuccess: Bool
    let clearErrorOnEdit: Bool
    let newNoteDelay: AppSettings.NewNoteDelay
    let lastBackgroundAt: Date?
    let lastActiveDraftID: UUID?
    let resumeDeadlineAt: Date?

    static func capture() -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            endpointBaseURL: AppSettings.endpointBaseURL,
            allowInsecureHTTP: AppSettings.allowInsecureHTTP,
            keepTextAfterSend: AppSettings.keepTextAfterSend,
            markSentOnSuccess: AppSettings.markSentOnSuccess,
            clearErrorOnEdit: AppSettings.clearErrorOnEdit,
            newNoteDelay: AppSettings.newNoteDelay,
            lastBackgroundAt: AppSettings.lastBackgroundAt,
            lastActiveDraftID: AppSettings.lastActiveDraftID,
            resumeDeadlineAt: AppSettings.resumeDeadlineAt
        )
    }

    func restore() {
        AppSettings.endpointBaseURL = endpointBaseURL
        AppSettings.allowInsecureHTTP = allowInsecureHTTP
        AppSettings.keepTextAfterSend = keepTextAfterSend
        AppSettings.markSentOnSuccess = markSentOnSuccess
        AppSettings.clearErrorOnEdit = clearErrorOnEdit
        AppSettings.newNoteDelay = newNoteDelay
        AppSettings.lastBackgroundAt = lastBackgroundAt
        AppSettings.lastActiveDraftID = lastActiveDraftID
        AppSettings.resumeDeadlineAt = resumeDeadlineAt
    }
}
