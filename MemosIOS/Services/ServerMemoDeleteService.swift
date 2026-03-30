import Foundation
import SwiftData

@MainActor
enum ServerMemoDeleteService {
    enum DeleteOutcome {
        case success
        case failure
    }

    @discardableResult
    static func enqueue(memoID: String, resourceName: String?, in modelContext: ModelContext) -> Bool {
        let normalizedMemoID = memoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMemoID.isEmpty else { return false }

        let normalizedResourceName = normalizeResourceName(
            resourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
            fallbackMemoID: normalizedMemoID
        )
        guard !normalizedResourceName.isEmpty else { return false }

        let task = upsertTask(memoID: normalizedMemoID, resourceName: normalizedResourceName, in: modelContext)
        task.resourceName = normalizedResourceName
        task.deleteState = .pending
        task.lastError = nil
        task.updatedAt = Date()
        modelContext.saveOrAssert()
        return true
    }

    static func hiddenMemoIDs(in modelContext: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<ServerMemoDeleteTask>()
        guard let tasks = try? modelContext.fetch(descriptor) else { return [] }
        return Set(tasks.map(\.memoID))
    }

    static func pendingTasks(in modelContext: ModelContext) -> [ServerMemoDeleteTask] {
        let descriptor = FetchDescriptor<ServerMemoDeleteTask>(
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        guard let allTasks = try? modelContext.fetch(descriptor) else {
            return []
        }
        return allTasks.filter { $0.deleteState == .pending }
    }

    static func attemptQueuedDelete(
        task: ServerMemoDeleteTask,
        in modelContext: ModelContext,
        client: MemosClient = MemosClient()
    ) async -> DeleteOutcome {
        let resourceName = task.resourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resourceName.isEmpty else {
            task.deleteState = .resolved
            task.lastError = nil
            task.updatedAt = Date()
            modelContext.saveOrAssert()
            return .success
        }

        task.deleteState = .deleting
        task.lastError = nil
        task.updatedAt = Date()
        modelContext.saveOrAssert()

        do {
            try await client.deleteMemo(
                resourceName: resourceName,
                baseURLString: AppSettings.endpointBaseURL,
                token: KeychainTokenStore.getToken(),
                allowInsecureHTTP: AppSettings.allowInsecureHTTP
            )

            task.deleteState = .resolved
            task.lastError = nil
            task.updatedAt = Date()
            modelContext.saveOrAssert()
            return .success
        } catch {
            task.deleteState = .pending
            task.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            task.updatedAt = Date()
            modelContext.saveOrAssert()
            return .failure
        }
    }

    static func pruneResolvedTasks(olderThan age: TimeInterval = 60 * 60 * 24 * 7, in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<ServerMemoDeleteTask>()
        guard let tasks = try? modelContext.fetch(descriptor) else { return }
        let threshold = Date().addingTimeInterval(-max(60, age))

        var deletedAny = false
        for task in tasks where task.deleteState == .resolved && task.updatedAt < threshold {
            modelContext.delete(task)
            deletedAny = true
        }

        if deletedAny {
            modelContext.saveOrAssert()
        }
    }

    private static func upsertTask(memoID: String, resourceName: String, in modelContext: ModelContext) -> ServerMemoDeleteTask {
        if let existing = task(memoID: memoID, in: modelContext) {
            return existing
        }

        let created = ServerMemoDeleteTask(
            memoID: memoID,
            resourceName: resourceName,
            deleteState: .pending
        )
        modelContext.insert(created)
        return created
    }

    private static func task(memoID: String, in modelContext: ModelContext) -> ServerMemoDeleteTask? {
        let descriptor = FetchDescriptor<ServerMemoDeleteTask>(
            predicate: #Predicate { $0.memoID == memoID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private static func normalizeResourceName(_ resourceName: String?, fallbackMemoID: String) -> String {
        if let resourceName, !resourceName.isEmpty {
            if resourceName.hasPrefix("memos/") {
                return resourceName
            }
            return "memos/\(resourceName)"
        }

        if fallbackMemoID.hasPrefix("memos/") {
            return fallbackMemoID
        }
        return "memos/\(fallbackMemoID)"
    }
}

@MainActor
final class ServerMemoDeleteQueueController: ObservableObject {
    private let client: MemosClient
    private var processingTask: Task<Void, Never>?
    private var failureCounts: [String: Int] = [:]
    private var nextAttemptAt: [String: Date] = [:]

    init(client: MemosClient = MemosClient()) {
        self.client = client
    }

    deinit {
        processingTask?.cancel()
    }

    @discardableResult
    func enqueue(memoID: String, resourceName: String?, in modelContext: ModelContext) -> Bool {
        let didQueue = ServerMemoDeleteService.enqueue(memoID: memoID, resourceName: resourceName, in: modelContext)
        guard didQueue else { return false }
        nextAttemptAt[memoID] = Date()
        ensureProcessing(in: modelContext)
        return true
    }

    func startProcessing(in modelContext: ModelContext) {
        primePendingTasks(in: modelContext)
        ensureProcessing(in: modelContext)
    }

    func retryNow(in modelContext: ModelContext) {
        let pending = ServerMemoDeleteService.pendingTasks(in: modelContext)
        for task in pending {
            nextAttemptAt[task.memoID] = Date()
        }
        ensureProcessing(in: modelContext)
    }

    func stopProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    private func primePendingTasks(in modelContext: ModelContext) {
        ServerMemoDeleteService.pruneResolvedTasks(in: modelContext)
        let pending = ServerMemoDeleteService.pendingTasks(in: modelContext)
        let pendingIDs = Set(pending.map(\.memoID))

        for task in pending where nextAttemptAt[task.memoID] == nil {
            nextAttemptAt[task.memoID] = Date()
        }

        failureCounts = failureCounts.filter { pendingIDs.contains($0.key) }
        nextAttemptAt = nextAttemptAt.filter { pendingIDs.contains($0.key) }
    }

    private func ensureProcessing(in modelContext: ModelContext) {
        guard processingTask == nil else { return }

        processingTask = Task { @MainActor [weak self] in
            defer { self?.processingTask = nil }
            guard let self else { return }

            while !Task.isCancelled {
                self.primePendingTasks(in: modelContext)
                let pending = ServerMemoDeleteService.pendingTasks(in: modelContext)
                guard !pending.isEmpty else {
                    break
                }

                let now = Date()
                var attemptedAny = false
                var earliestNextAttempt = now.addingTimeInterval(300)

                for task in pending {
                    let attemptTime = self.nextAttemptAt[task.memoID] ?? .distantPast
                    if attemptTime > now {
                        earliestNextAttempt = min(earliestNextAttempt, attemptTime)
                        continue
                    }

                    attemptedAny = true
                    let outcome = await ServerMemoDeleteService.attemptQueuedDelete(
                        task: task,
                        in: modelContext,
                        client: self.client
                    )

                    switch outcome {
                    case .success:
                        self.failureCounts[task.memoID] = nil
                        self.nextAttemptAt[task.memoID] = nil
                    case .failure:
                        let failureCount = (self.failureCounts[task.memoID] ?? 0) + 1
                        self.failureCounts[task.memoID] = failureCount
                        let retryDate = Date().addingTimeInterval(Self.backoffDelay(for: failureCount))
                        self.nextAttemptAt[task.memoID] = retryDate
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
