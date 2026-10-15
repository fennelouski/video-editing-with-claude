import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private final class FrameReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var opened = false
    private var queuedBodyRan = false
    private var finished = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    var queuedRan: Bool { condition.lock(); defer { condition.unlock() }; return queuedBodyRan }
    var completed: Bool { condition.lock(); defer { condition.unlock() }; return finished }
    func complete() { condition.lock(); finished = true; condition.unlock() }
    func hold() { condition.lock(); started = true; condition.broadcast(); while !opened { condition.wait() }; condition.unlock() }
    func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
    func markQueuedBody() { condition.lock(); queuedBodyRan = true; condition.unlock() }
}
struct FrameBlockingExecutorTests {
    @Test func rejectedDuplicateCancellationCannotCancelTheOriginalOwner() async throws {
        let executor = FrameBlockingExecutor(label: "clauto.synthetic.duplicate-cancel",capacity: 1), gate = FrameReadGate(), ownerDone = FrameReadGate(), job = FrameBlockingJob<Int>()
        defer { gate.open() }
        let owner = Task { () -> Result<Int,any Error> in
            defer { ownerDone.complete() }
            do { return .success(try await executor.perform(job: job) { _ in gate.hold(); return 81 }) }
            catch { return .failure(error) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        for _ in 0..<128 {
            if ownerDone.completed { break }
            let duplicates = (0..<32).map { _ in Task { _ = try? await executor.perform(job: job) { _ in gate.markQueuedBody(); return 82 } } }
            await withTaskGroup(of: Void.self) { group in
                for duplicate in duplicates { group.addTask { await Task.yield(); duplicate.cancel(); await duplicate.value } }
            }
        }
        #expect(!ownerDone.completed && !owner.isCancelled && !gate.queuedRan && executor.inFlight == 1)
        gate.open()
        switch await owner.value {
        case .success(let value): #expect(value == 81)
        case .failure: Issue.record("A rejected duplicate cancelled the original job's owner")
        }
    }
    @Test func captureStyleTokenCancellationReleasesItsWaiterAndRetainsThePhysicalSlot() async throws {
        let executor = FrameBlockingExecutor(label: "clauto.synthetic.manual-cancel",capacity: 1), gate = FrameReadGate(), job = FrameBlockingJob<Int>()
        defer { gate.open() }
        let task = Task { try await executor.perform(job: job) { _ in gate.hold(); return 12 } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.entered)
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!task.isCancelled && executor.inFlight == 1)
        await #expect(throws: (any Error).self) { _ = try await executor.perform(job: FrameBlockingJob<Int>()) { _ in 13 } }
        gate.open()
        while executor.inFlight != 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(executor.inFlight == 0)
    }
    @Test func cancellationReleasesWaitersButKeepsPhysicalCapacityUntilTheBlockedWorkReturns() async throws {
        let executor = FrameBlockingExecutor(label: "clauto.synthetic.blocking-boundary",capacity: 2), gate = FrameReadGate()
        defer { gate.open() }
        let first = Task { try await executor.perform(job: FrameBlockingJob<Int>()) { _ in gate.hold(); return 11 } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.entered)
        let second = Task { try await executor.perform(job: FrameBlockingJob<Int>()) { _ in gate.markQueuedBody(); return 22 } }
        while executor.inFlight != 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(executor.inFlight == 2)
        first.cancel(); second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        #expect(executor.inFlight == 2 && !gate.queuedRan)
        await #expect(throws: (any Error).self) { _ = try await executor.perform(job: FrameBlockingJob<Int>()) { _ in 33 } }
        #expect(executor.inFlight == 2)
        gate.open()
        while executor.inFlight != 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(executor.inFlight == 0 && !gate.queuedRan)
        #expect(try await executor.perform(job: FrameBlockingJob<Int>()) { _ in 44 } == 44)
    }
    @Test func cancelledBeforeBindingAndConsumedJobsCannotPublishOrRunAnotherOperation() async throws {
        let executor = FrameBlockingExecutor(label: "clauto.synthetic.once-boundary",capacity: 2), gate = FrameReadGate()
        let cancelled = FrameBlockingJob<Int>(); cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await executor.perform(job: cancelled) { _ in gate.markQueuedBody(); return 1 } }
        #expect(executor.inFlight == 0 && !gate.queuedRan)
        let consumed = FrameBlockingJob<Int>()
        #expect(try await executor.perform(job: consumed) { _ in 7 } == 7)
        await #expect(throws: (any Error).self) { _ = try await executor.perform(job: consumed) { _ in gate.markQueuedBody(); return 8 } }
        #expect(!gate.queuedRan)
    }
}
