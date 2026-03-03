import Foundation
import SwiftData

@MainActor
enum DraftSendService {
    enum SendOutcome {
        case success
        case failure
    }

    static func send(draft: Draft, in modelContext: ModelContext, client: MemosClient = MemosClient()) async -> SendOutcome {
        let trimmedContent = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            draft.lastError = "Draft is empty."
            draft.sendState = .failed
            modelContext.saveOrAssert()
            return .failure
        }

        draft.sendState = .sending
        draft.lastError = nil
        modelContext.saveOrAssert()

        do {
            try await client.createMemo(
                content: draft.text,
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP
            )

            draft.lastSentAt = Date()
            draft.sendState = AppSettings.markSentOnSuccess ? .sent : .idle
            draft.lastError = nil
            draft.isArchived = true

            if !AppSettings.keepTextAfterSend {
                draft.text = ""
                draft.updatedAt = Date()
            }

            modelContext.saveOrAssert()
            return .success
        } catch {
            draft.sendState = .failed
            draft.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            modelContext.saveOrAssert()
            return .failure
        }
    }
}
