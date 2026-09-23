import Foundation
import SwiftData

@MainActor
enum DraftResumeCoordinator {
    static func preferredDraft(from allDrafts: [Draft], in modelContext: ModelContext, now: Date = Date()) -> Draft {
        let activeDrafts = allDrafts.filter { !$0.isArchived }
        let reusableBlank = collapseTransientBlanks(in: activeDrafts, modelContext: modelContext)

        if shouldResumePreviousDraft(now: now),
           let lastID = AppSettings.lastActiveDraftID,
           let lastDraft = activeDrafts.first(where: { $0.id == lastID }),
           lastDraft.hasStartedText {
            return lastDraft
        }

        if let reusableBlank {
            markActiveDraft(reusableBlank)
            return reusableBlank
        }

        return blankDraft(in: modelContext)
    }

    static func markAppBackgrounded(now: Date = Date()) {
        AppSettings.lastBackgroundAt = now
        let option = AppSettings.newNoteDelay
        guard let delay = option.delaySeconds else {
            AppSettings.resumeDeadlineAt = nil
            return
        }

        if delay <= 0 {
            AppSettings.resumeDeadlineAt = nil
            return
        }

        AppSettings.resumeDeadlineAt = now.addingTimeInterval(TimeInterval(delay))
    }

    static func markActiveDraft(_ draft: Draft?) {
        AppSettings.lastActiveDraftID = draft?.id
    }

    static func shouldResumePreviousDraft(now: Date) -> Bool {
        if AppSettings.newNoteDelay == .never {
            return true
        }

        if AppSettings.newNoteDelay == .immediately {
            return false
        }

        guard let deadline = AppSettings.resumeDeadlineAt else { return false }
        return now <= deadline
    }

    private static func blankDraft(in modelContext: ModelContext) -> Draft {
        let draft = DraftStore.createDraft(in: modelContext)
        markActiveDraft(draft)
        return draft
    }

    private static func collapseTransientBlanks(in activeDrafts: [Draft], modelContext: ModelContext) -> Draft? {
        let blanks = activeDrafts.filter(\.isTransientBlankUnsent)
        guard !blanks.isEmpty else { return nil }

        if blanks.count > 1 {
            for duplicate in blanks.dropFirst() {
                modelContext.delete(duplicate)
            }
            modelContext.saveOrAssert()
        }

        return blanks.first
    }
}
