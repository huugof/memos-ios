import XCTest
@testable import Quoote

final class AsyncGateTests: XCTestCase {

    private actor Probe {
        private(set) var active = 0
        private(set) var peak = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
    }

    func testNeverAdmitsMoreThanTheLimit() async throws {
        let gate = AsyncGate(limit: 2)
        let probe = Probe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await gate.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await probe.leave()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }

        let peak = await probe.peak
        XCTAssertEqual(peak, 2)
    }

    func testAWaiterThatIsCancelledNeverRunsAndLeaksNoSlot() async throws {
        let gate = AsyncGate(limit: 1)
        try await gate.acquire()   // holds the only slot

        let ran = expectation(description: "cancelled waiter ran")
        ran.isInverted = true
        let waiter = Task {
            try await gate.acquire()
            ran.fulfill()
            await gate.release()
        }
        await waitUntil(gate, hasWaiting: 1)
        waiter.cancel()

        let result = await waiter.result
        guard case .failure(let error) = result else { return XCTFail("a cancelled waiter must not acquire") }
        XCTAssertTrue(error is CancellationError)
        await fulfillment(of: [ran], timeout: 0.2)

        await gate.release()
        // The slot is free again: a new task gets in immediately rather than behind a ghost.
        let next = Task { try await gate.acquire(); await gate.release() }
        let finished = await next.result
        XCTAssertNoThrow(try finished.get())
    }

    func testWaitersAreAdmittedInArrivalOrder() async throws {
        let gate = AsyncGate(limit: 1)
        try await gate.acquire()

        let order = OrderLog()
        var tasks: [Task<Void, Error>] = []
        for index in 0..<3 {
            tasks.append(Task {
                try await gate.acquire()
                await order.append(index)
                await gate.release()
            })
            await waitUntil(gate, hasWaiting: index + 1)   // arrive one after another
        }
        await gate.release()
        for task in tasks { try await task.value }

        let admitted = await order.values
        XCTAssertEqual(admitted, [0, 1, 2])
    }

    /// Waits (up to two seconds) until `count` tasks are queued behind the gate.
    private func waitUntil(_ gate: AsyncGate, hasWaiting count: Int) async {
        for _ in 0..<400 where await gate.waitingCount < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.waitingCount
        XCTAssertGreaterThanOrEqual(waiting, count)
    }

    private actor OrderLog {
        private(set) var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }

    func testATaskCancelledBeforeItStartsNeverAcquires() async {
        let gate = AsyncGate(limit: 1)
        let task = Task {
            try await Task.sleep(for: .milliseconds(100))   // outlives the cancel below
            try await gate.acquire()
        }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get())
    }
}
