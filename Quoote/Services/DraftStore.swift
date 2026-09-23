import Foundation
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

    @discardableResult
    static func deleteInactiveTransientBlankDrafts(
        preserving preservedDraftID: UUID?,
        from drafts: [Draft],
        in modelContext: ModelContext
    ) -> [UUID] {
        let staleDrafts = drafts.filter { draft in
            draft.isTransientBlankUnsent && draft.id != preservedDraftID
        }
        guard !staleDrafts.isEmpty else { return [] }

        let deletedIDs = staleDrafts.map(\.id)
        delete(staleDrafts, in: modelContext)
        return deletedIDs
    }

    static func visibleUnsentDrafts(from drafts: [Draft]) -> [Draft] {
        drafts.filter { draft in
            guard !draft.isArchived else { return false }
            guard draft.sendState != .pending && draft.sendState != .sending else {
                return false
            }
            return !draft.isTransientBlankUnsent
        }
    }
}
