import Foundation
import Combine
import SwiftData

@MainActor
enum DraftSendService {
    enum SendOutcome {
        case success
        case failure
    }

    @discardableResult
    static func enqueue(draft: Draft, in modelContext: ModelContext) -> Bool {
        let trimmedContent = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            draft.lastError = "Draft is empty."
            draft.sendState = .failed
            modelContext.saveOrAssert()
            return false
        }

        guard draft.sendState != .sending && draft.sendState != .pending else {
            return false
        }

        draft.sendState = .pending
        draft.lastError = nil
        modelContext.saveOrAssert()
        return true
    }

    static func pendingDrafts(in modelContext: ModelContext) -> [Draft] {
        let descriptor = FetchDescriptor<Draft>(sortBy: [SortDescriptor(\.updatedAt, order: .forward)])
        guard let allDrafts = try? modelContext.fetch(descriptor) else {
            return []
        }

        return allDrafts.filter { !$0.isArchived && $0.sendState == .pending }
    }

    static func attemptQueuedSend(
        draft: Draft,
        in modelContext: ModelContext,
        client: MemosClient = MemosClient()
    ) async -> SendOutcome {
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
            draft.sendState = .pending
            draft.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            modelContext.saveOrAssert()
            return .failure
        }
    }
}

@MainActor
final class DraftSendQueueController: ObservableObject {
    private let client: MemosClient

    private var processingTask: Task<Void, Never>?
    private var failureCounts: [UUID: Int] = [:]
    private var nextAttemptAt: [UUID: Date] = [:]

    init(client: MemosClient = MemosClient()) {
        self.client = client
    }

    @discardableResult
    func enqueue(_ draft: Draft, in modelContext: ModelContext) -> Bool {
        if draft.sendState == .pending {
            nextAttemptAt[draft.id] = Date()
            ensureProcessing(in: modelContext)
            return true
        }

        let didQueue = DraftSendService.enqueue(draft: draft, in: modelContext)
        guard didQueue else { return false }
        nextAttemptAt[draft.id] = Date()
        ensureProcessing(in: modelContext)
        return true
    }

    func startProcessing(in modelContext: ModelContext) {
        primePendingDrafts(in: modelContext)
        ensureProcessing(in: modelContext)
    }

    func retryNow(in modelContext: ModelContext) {
        let pending = DraftSendService.pendingDrafts(in: modelContext)
        for draft in pending {
            nextAttemptAt[draft.id] = Date()
        }
        ensureProcessing(in: modelContext)
    }

    func stopProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    private func primePendingDrafts(in modelContext: ModelContext) {
        let pending = DraftSendService.pendingDrafts(in: modelContext)
        let pendingIDs = Set(pending.map(\.id))

        for draft in pending where nextAttemptAt[draft.id] == nil {
            nextAttemptAt[draft.id] = Date()
        }

        failureCounts = failureCounts.filter { pendingIDs.contains($0.key) }
        nextAttemptAt = nextAttemptAt.filter { pendingIDs.contains($0.key) }
    }

    private func ensureProcessing(in modelContext: ModelContext) {
        guard processingTask == nil else { return }

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                self.primePendingDrafts(in: modelContext)
                let pending = DraftSendService.pendingDrafts(in: modelContext)
                guard !pending.isEmpty else {
                    break
                }

                let now = Date()
                var attemptedAny = false
                var earliestNextAttempt = now.addingTimeInterval(300)

                for draft in pending {
                    let attemptTime = self.nextAttemptAt[draft.id] ?? .distantPast
                    if attemptTime > now {
                        earliestNextAttempt = min(earliestNextAttempt, attemptTime)
                        continue
                    }

                    attemptedAny = true
                    let outcome = await DraftSendService.attemptQueuedSend(
                        draft: draft,
                        in: modelContext,
                        client: self.client
                    )

                    switch outcome {
                    case .success:
                        self.failureCounts[draft.id] = nil
                        self.nextAttemptAt[draft.id] = nil
                    case .failure:
                        let failureCount = (self.failureCounts[draft.id] ?? 0) + 1
                        self.failureCounts[draft.id] = failureCount
                        let retryDate = Date().addingTimeInterval(Self.backoffDelay(for: failureCount))
                        self.nextAttemptAt[draft.id] = retryDate
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
