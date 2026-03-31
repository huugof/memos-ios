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
        sendQueue: DraftSendQueueController,
        setActiveDraftID: (UUID) -> Void
    ) {
        guard let backgroundAt = AppSettings.lastBackgroundAt else { return }
        AppSettings.lastBackgroundAt = nil

        guard let delaySeconds = AppSettings.newNoteDelay.delaySeconds, delaySeconds > 0 else { return }

        let elapsed = Date().timeIntervalSince(backgroundAt)
        guard elapsed >= TimeInterval(delaySeconds) else { return }

        guard let activeDraftID,
              let activeDraft = allDrafts.first(where: { $0.id == activeDraftID }),
              activeDraft.hasStartedText else { return }

        sendQueue.enqueue(activeDraft, in: modelContext)

        let newDraft = DraftStore.createDraft(in: modelContext)
        setActiveDraftID(newDraft.id)
    }
}
