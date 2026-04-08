import Foundation
import SwiftData

@MainActor
enum ChatAutoCommitCoordinator {
    static func onBackground() {
        AppSettings.lastBackgroundAt = Date()
    }

    static func onForeground(
        activeDraftID: UUID?,
        allDrafts: [Draft],
        modelContext: ModelContext,
        setActiveDraftID: (UUID) -> Void
    ) {
        guard let backgroundAt = AppSettings.lastBackgroundAt else { return }
        AppSettings.lastBackgroundAt = nil

        guard let delaySeconds = AppSettings.newNoteDelay.delaySeconds else { return }

        let elapsed = Date().timeIntervalSince(backgroundAt)
        guard elapsed >= TimeInterval(delaySeconds) else { return }

        guard let activeDraftID,
              let candidate = allDrafts.first(where: { $0.id == activeDraftID }),
              candidate.hasStartedText else { return }

        // The candidate draft is left as-is: local, not enqueued for server upload.
        // Create a new blank draft so the next capture starts fresh.

        let newDraft = DraftStore.createDraft(in: modelContext)
        setActiveDraftID(newDraft.id)
    }
}
