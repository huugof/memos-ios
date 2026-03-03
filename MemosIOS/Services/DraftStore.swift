import SwiftData

@MainActor
enum DraftStore {
    static func createDraft(in modelContext: ModelContext, text: String = "") -> Draft {
        let draft = Draft(text: text)
        modelContext.insert(draft)
        modelContext.saveOrAssert()
        return draft
    }

    static func duplicate(_ draft: Draft, in modelContext: ModelContext) -> Draft {
        let duplicate = Draft(text: draft.text)
        duplicate.lastSentAt = nil
        duplicate.sendState = .idle
        duplicate.lastError = nil
        duplicate.isArchived = false
        modelContext.insert(duplicate)
        modelContext.saveOrAssert()
        return duplicate
    }

    static func delete(_ draft: Draft, in modelContext: ModelContext) {
        delete([draft], in: modelContext)
    }

    static func delete(_ drafts: [Draft], in modelContext: ModelContext) {
        guard !drafts.isEmpty else { return }

        var shouldClearActiveDraft = false
        let activeID = AppSettings.lastActiveDraftID

        for draft in drafts {
            if activeID == draft.id {
                shouldClearActiveDraft = true
            }
            modelContext.delete(draft)
        }

        if shouldClearActiveDraft {
            DraftResumeCoordinator.markActiveDraft(nil)
        }

        modelContext.saveOrAssert()
    }

    @discardableResult
    static func deleteTransientBlankIfNeeded(_ draft: Draft, in modelContext: ModelContext) -> Bool {
        guard draft.isTransientBlankUnsent else { return false }
        delete(draft, in: modelContext)
        return true
    }

    static func filteredDrafts(_ drafts: [Draft], scope: DraftScope) -> [Draft] {
        drafts.filter { scope.includes($0) }
    }
}
