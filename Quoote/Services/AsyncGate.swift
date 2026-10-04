import Foundation

/// Admits at most `limit` holders at a time. The rest wait in the order they arrived, and a waiter whose task is
/// cancelled drops out without ever holding a slot.
actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// How many tasks are waiting for a slot right now. Lets a test wait for a queue to form instead of sleeping.
    var waitingCount: Int { waiters.count }

    /// Suspends until a slot is free. Throws `CancellationError` if the task is cancelled while it waits.
    /// Every `acquire()` that returns must be paired with exactly one `release()`.
    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            running -= 1
            return
        }
        // The slot passes straight to the longest-waiting task, so `running` stays put.
        waiters.removeFirst().continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
