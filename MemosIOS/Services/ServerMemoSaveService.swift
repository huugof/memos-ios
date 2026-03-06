import Foundation
import Combine
import SwiftData

@MainActor
enum ServerMemoSaveService {
    enum SaveOutcome {
        case success(ServerMemoSummary)
        case failure
    }

    static func upsertEditDraft(for memo: ServerMemoSummary, in modelContext: ModelContext) -> ServerMemoEditDraft {
        if let existing = draft(memoID: memo.id, in: modelContext) {
            existing.resourceName = memo.resourceName ?? existing.resourceName
            if existing.saveState == .idle && !existing.hasLocalChanges {
                existing.serverContent = memo.content
                existing.localContent = memo.content
                existing.updatedAt = Date()
            }
            if existing.resourceName.isEmpty, let resourceName = memo.resourceName {
                existing.resourceName = resourceName
            }
            modelContext.saveOrAssert()
            return existing
        }

        let resourceName = memo.resourceName ?? memo.id
        let created = ServerMemoEditDraft(
            memoID: memo.id,
            resourceName: resourceName,
            serverContent: memo.content,
            localContent: memo.content
        )
        modelContext.insert(created)
        modelContext.saveOrAssert()
        return created
    }

    static func draft(memoID: String, in modelContext: ModelContext) -> ServerMemoEditDraft? {
        let descriptor = FetchDescriptor<ServerMemoEditDraft>(
            predicate: #Predicate { $0.memoID == memoID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    @discardableResult
    static func stageLocalContent(_ content: String, for editDraft: ServerMemoEditDraft, in modelContext: ModelContext) -> Bool {
        return stageLocalContent(content, for: editDraft, in: modelContext, persist: true)
    }

    @discardableResult
    static func stageLocalContent(
        _ content: String,
        for editDraft: ServerMemoEditDraft,
        in modelContext: ModelContext,
        persist: Bool
    ) -> Bool {
        guard editDraft.localContent != content else { return false }
        editDraft.localContent = content
        editDraft.updatedAt = Date()

        if editDraft.saveState == .saving {
            editDraft.saveState = .pending
        }

        if editDraft.hasLocalChanges {
            // Keep existing error visible until next explicit save/retry.
        } else {
            editDraft.lastError = nil
            if editDraft.saveState == .pending {
                editDraft.saveState = .idle
            }
        }

        if persist {
            modelContext.saveOrAssert()
        }
        return true
    }

    @discardableResult
    static func enqueue(editDraft: ServerMemoEditDraft, in modelContext: ModelContext) -> Bool {
        let trimmed = editDraft.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editDraft.saveState = .idle
            editDraft.lastError = "Note is empty."
            modelContext.saveOrAssert()
            return false
        }

        guard editDraft.hasLocalChanges || editDraft.saveState == .pending else {
            return false
        }

        if editDraft.resourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editDraft.saveState = .idle
            editDraft.lastError = "This note cannot be edited on this server."
            modelContext.saveOrAssert()
            return false
        }

        editDraft.localContent = trimmed
        editDraft.saveState = .pending
        editDraft.lastError = nil
        editDraft.updatedAt = Date()
        modelContext.saveOrAssert()
        return true
    }

    static func pendingEdits(in modelContext: ModelContext) -> [ServerMemoEditDraft] {
        let descriptor = FetchDescriptor<ServerMemoEditDraft>(sortBy: [SortDescriptor(\.updatedAt, order: .forward)])
        guard let all = try? modelContext.fetch(descriptor) else {
            return []
        }

        return all.filter { $0.saveState == .pending }
    }

    static func attemptQueuedSave(
        editDraft: ServerMemoEditDraft,
        in modelContext: ModelContext,
        client: MemosClient = MemosClient()
    ) async -> SaveOutcome {
        let trimmed = editDraft.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editDraft.saveState = .idle
            editDraft.lastError = "Note is empty."
            modelContext.saveOrAssert()
            return .failure
        }

        let resourceName = editDraft.resourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resourceName.isEmpty else {
            editDraft.saveState = .idle
            editDraft.lastError = "This note cannot be edited on this server."
            modelContext.saveOrAssert()
            return .failure
        }

        editDraft.saveState = .saving
        editDraft.lastError = nil
        editDraft.updatedAt = Date()
        modelContext.saveOrAssert()

        do {
            var updated = try await client.updateMemoContent(
                resourceName: resourceName,
                content: trimmed,
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP
            )

            if updated.id != editDraft.memoID {
                updated = ServerMemoSummary(
                    id: editDraft.memoID,
                    resourceName: updated.resourceName ?? resourceName,
                    content: updated.content,
                    updatedAt: updated.updatedAt
                )
            }

            editDraft.serverContent = trimmed
            editDraft.localContent = trimmed
            editDraft.saveState = .idle
            editDraft.lastError = nil
            editDraft.lastSyncedAt = Date()
            editDraft.updatedAt = Date()
            modelContext.saveOrAssert()
            return .success(updated)
        } catch {
            editDraft.saveState = .pending
            editDraft.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            editDraft.updatedAt = Date()
            modelContext.saveOrAssert()
            return .failure
        }
    }
}

@MainActor
final class ServerMemoSaveQueueController: ObservableObject {
    @Published private(set) var lastSuccessfulMemo: ServerMemoSummary?

    private let client: MemosClient
    private var processingTask: Task<Void, Never>?
    private var failureCounts: [String: Int] = [:]
    private var nextAttemptAt: [String: Date] = [:]

    init(client: MemosClient = MemosClient()) {
        self.client = client
    }

    @discardableResult
    func enqueue(_ editDraft: ServerMemoEditDraft, in modelContext: ModelContext) -> Bool {
        if editDraft.saveState == .pending {
            nextAttemptAt[editDraft.memoID] = Date()
            ensureProcessing(in: modelContext)
            return true
        }

        let didQueue = ServerMemoSaveService.enqueue(editDraft: editDraft, in: modelContext)
        guard didQueue else { return false }
        nextAttemptAt[editDraft.memoID] = Date()
        ensureProcessing(in: modelContext)
        return true
    }

    func startProcessing(in modelContext: ModelContext) {
        primePendingEdits(in: modelContext)
        ensureProcessing(in: modelContext)
    }

    func retryNow(in modelContext: ModelContext) {
        let pending = ServerMemoSaveService.pendingEdits(in: modelContext)
        for editDraft in pending {
            nextAttemptAt[editDraft.memoID] = Date()
        }
        ensureProcessing(in: modelContext)
    }

    func stopProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    func saveNow(_ editDraft: ServerMemoEditDraft, in modelContext: ModelContext) async -> ServerMemoSaveService.SaveOutcome {
        let didQueue = enqueue(editDraft, in: modelContext)
        guard didQueue || editDraft.saveState == .pending else {
            return .failure
        }

        let outcome = await ServerMemoSaveService.attemptQueuedSave(
            editDraft: editDraft,
            in: modelContext,
            client: client
        )

        switch outcome {
        case .success(let memo):
            failureCounts[editDraft.memoID] = nil
            nextAttemptAt[editDraft.memoID] = nil
            lastSuccessfulMemo = memo
        case .failure:
            let failureCount = (failureCounts[editDraft.memoID] ?? 0) + 1
            failureCounts[editDraft.memoID] = failureCount
            nextAttemptAt[editDraft.memoID] = Date().addingTimeInterval(Self.backoffDelay(for: failureCount))
            ensureProcessing(in: modelContext)
        }

        return outcome
    }

    private func primePendingEdits(in modelContext: ModelContext) {
        let pending = ServerMemoSaveService.pendingEdits(in: modelContext)
        let pendingIDs = Set(pending.map(\.memoID))

        for editDraft in pending where nextAttemptAt[editDraft.memoID] == nil {
            nextAttemptAt[editDraft.memoID] = Date()
        }

        failureCounts = failureCounts.filter { pendingIDs.contains($0.key) }
        nextAttemptAt = nextAttemptAt.filter { pendingIDs.contains($0.key) }
    }

    private func ensureProcessing(in modelContext: ModelContext) {
        guard processingTask == nil else { return }

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                self.primePendingEdits(in: modelContext)
                let pending = ServerMemoSaveService.pendingEdits(in: modelContext)
                guard !pending.isEmpty else {
                    break
                }

                let now = Date()
                var attemptedAny = false
                var earliestNextAttempt = now.addingTimeInterval(300)

                for editDraft in pending {
                    let attemptTime = self.nextAttemptAt[editDraft.memoID] ?? .distantPast
                    if attemptTime > now {
                        earliestNextAttempt = min(earliestNextAttempt, attemptTime)
                        continue
                    }

                    attemptedAny = true
                    let outcome = await ServerMemoSaveService.attemptQueuedSave(
                        editDraft: editDraft,
                        in: modelContext,
                        client: self.client
                    )

                    switch outcome {
                    case .success(let memo):
                        self.failureCounts[editDraft.memoID] = nil
                        self.nextAttemptAt[editDraft.memoID] = nil
                        self.lastSuccessfulMemo = memo
                    case .failure:
                        let failureCount = (self.failureCounts[editDraft.memoID] ?? 0) + 1
                        self.failureCounts[editDraft.memoID] = failureCount
                        let retryDate = Date().addingTimeInterval(Self.backoffDelay(for: failureCount))
                        self.nextAttemptAt[editDraft.memoID] = retryDate
                        earliestNextAttempt = min(earliestNextAttempt, retryDate)
                    }
                }

                if !attemptedAny {
                    let sleepSeconds = max(1, min(300, earliestNextAttempt.timeIntervalSinceNow))
                    try? await Task.sleep(for: .seconds(sleepSeconds))
                } else {
                    await Task.yield()
                }
            }

            self.processingTask = nil
        }
    }

    private static func backoffDelay(for failureCount: Int) -> TimeInterval {
        switch failureCount {
        case 1:
            return 5
        case 2:
            return 15
        case 3:
            return 30
        case 4:
            return 60
        case 5:
            return 120
        default:
            return 300
        }
    }
}
