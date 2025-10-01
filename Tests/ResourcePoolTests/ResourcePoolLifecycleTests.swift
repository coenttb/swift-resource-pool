import Testing
import Foundation
@testable import ResourcePool

@Suite("ResourcePool - Lifecycle & Cleanup")
struct ResourcePoolLifecycleTests {

    @Test("Pool cleanup on close")
    func testPoolCleanup() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )

        let task1 = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .seconds(1))
            }
        }
        
        let task2 = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .seconds(1))
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        await pool.close()

        let stats = await pool.statistics
        #expect(stats.available == 0)

        task1.cancel()
        task2.cancel()
        _ = try? await task1.value
        _ = try? await task2.value
    }

    @Test("Drain waits for resources to return")
    func testDrainWaitsForResources() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(),
            warmup: true
        )
        
        let operation = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        
        try await Task.sleep(for: .milliseconds(50))
        
        let drainTask = Task {
            try await pool.drain(timeout: .seconds(1))
        }
        
        _ = try await operation.value
        _ = try await drainTask.value
        
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
    }

    @Test("Drain times out if resources not returned")
    func testDrainTimeout() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        let operation = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .seconds(10))
            }
        }
        
        try await Task.sleep(for: .milliseconds(50))
        
        do {
            try await pool.drain(timeout: .milliseconds(100))
            Issue.record("Should have timed out")
        } catch PoolError.drainTimeout {
            // Expected
        }
        
        operation.cancel()
        _ = try? await operation.value
    }

    @Test("Drain prevents new acquisitions")
    func testDrainPreventsNewAcquisitions() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        let drainTask = Task {
            try await pool.drain(timeout: .seconds(1))
        }
        
        try await Task.sleep(for: .milliseconds(50))
        
        do {
            _ = try await pool.withResource { $0.id }
            Issue.record("Should have failed with closed error")
        } catch PoolError.closed {
            // Expected
        }
        
        _ = try? await drainTask.value
    }

    @Test("Drain resumes all waiters with closed error")
    func testDrainResumesWaiters() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 1,
            resourceConfig: .init(),
            warmup: true
        )
        
        actor ErrorTracker {
            var closedErrors = 0
            func recordClosed() { closedErrors += 1 }
        }
        let tracker = ErrorTracker()
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Hold resource
            group.addTask {
                try await pool.withResource { _ in
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            
            try await Task.sleep(for: .milliseconds(50))
            
            // Queue multiple waiters
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await pool.withResource(timeout: .seconds(5)) { _ in
                            Issue.record("Should not succeed")
                        }
                    } catch PoolError.closed {
                        await tracker.recordClosed()
                    }
                }
            }
            
            try await Task.sleep(for: .milliseconds(50))
            
            // Drain should resume all waiters
            try? await pool.drain(timeout: .milliseconds(100))
            
            try await group.waitForAll()
        }
        
        let closedErrors = await tracker.closedErrors
        #expect(closedErrors == 5)
    }

    @Test("Close prevents new acquisitions immediately")
    func testCloseBlocksAcquisitions() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        await pool.close()
        
        do {
            _ = try await pool.withResource { $0.id }
            Issue.record("Should have thrown closed error")
        } catch PoolError.closed {
            // Expected
        }
    }

    @Test("Concurrent close and acquire")
    func testCloseRaceCondition() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        await withTaskGroup(of: Void.self) { group in
            // Start acquisitions
            for _ in 0..<10 {
                group.addTask {
                    do {
                        _ = try await pool.withResource(timeout: .milliseconds(100)) { _ in
                            try await Task.sleep(for: .milliseconds(200))
                        }
                    } catch {
                        // Some will fail with closed error
                    }
                }
            }
            
            try? await Task.sleep(for: .milliseconds(50))
            await pool.close()
            
            await group.waitForAll()
        }
        
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
        
        // New acquisitions should fail
        do {
            _ = try await pool.withResource { $0.id }
            Issue.record("Should have thrown closed error")
        } catch PoolError.closed {
            // Expected
        }
    }

    @Test("Resources returned during close are handled")
    func testResourceReturnDuringClose() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        let task1 = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        
        try await Task.sleep(for: .milliseconds(50))
        
        // Close while resource is leased
        await pool.close()
        
        // Task should complete, resource returned but discarded
        _ = try? await task1.value
        
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
    }

    @Test("Cancellation during resource acquisition")
    func testCancellationDuringAcquisition() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 1,
            resourceConfig: .init(),
            warmup: true
        )
        
        let holder = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .seconds(5))
            }
        }
        
        try await Task.sleep(for: .milliseconds(50))
        
        let waiter = Task {
            try await pool.withResource(timeout: .seconds(10)) { _ in
                Issue.record("Should not acquire after cancellation")
            }
        }
        
        try await Task.sleep(for: .milliseconds(50))
        
        // Verify waiter is queued
        let statsDuringWait = await pool.statistics
        #expect(statsDuringWait.waitQueueDepth == 1)
        
        // Cancel the waiter
        waiter.cancel()
        
        // Wait for cancellation to process
        _ = try? await waiter.value
        
        // Clean up
        holder.cancel()
        _ = try? await holder.value
    }

    @Test("Cancellation during resource usage")
    func testCancellationDuringUsage() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        let task = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .seconds(10))
            }
        }
        
        try await Task.sleep(for: .milliseconds(50))
        
        let statsDuring = await pool.statistics
        #expect(statsDuring.leased == 1)
        
        task.cancel()
        _ = try? await task.value
        
        // Resource should be returned after cancellation
        try await Task.sleep(for: .milliseconds(100))
        
        let statsAfter = await pool.statistics
        #expect(statsAfter.leased == 0)
        #expect(statsAfter.available == 2)
    }

    @Test("Multiple sequential drain/close cycles")
    func testMultipleDrainCloseCycles() async throws {
        for _ in 0..<3 {
            let pool = try await ResourcePool<MockResource>(
                capacity: 3,
                resourceConfig: .init(),
                warmup: true
            )
            
            // Use some resources
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        try await pool.withResource { _ in
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                }
                try await group.waitForAll()
            }
            
            // Drain
            try await pool.drain(timeout: .seconds(1))
            
            // Verify closed
            let stats = await pool.statistics
            #expect(stats.leased == 0)
            #expect(stats.available == 0)
        }
    }

    @Test("Close during resource reset")
    func testCloseDuringReset() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(resetDelay: .milliseconds(100)),
            warmup: true
        )
        
        let task = Task {
            try await pool.withResource { _ in
                // Quick use
            }
        }
        
        _ = try? await task.value
        
        // Close immediately after (during reset)
        await pool.close()
        
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
    }

    @Test("Waiters handled correctly after close")
    func testWaitersAfterClose() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 1,
            resourceConfig: .init(),
            warmup: true
        )
        
        actor ClosedErrorCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let counter = ClosedErrorCounter()
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Hold resource
            group.addTask {
                try await pool.withResource { _ in
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            
            try await Task.sleep(for: .milliseconds(50))
            
            // Start multiple waiters
            for _ in 0..<10 {
                group.addTask {
                    do {
                        try await pool.withResource(timeout: .seconds(5)) { _ in }
                    } catch PoolError.closed {
                        await counter.increment()
                    }
                }
            }
            
            try await Task.sleep(for: .milliseconds(50))
            await pool.close()
            
            try await group.waitForAll()
        }
        
        let closedCount = await counter.count
        #expect(closedCount == 10)
    }

    @Test("Resource accounting after close")
    func testAccountingAfterClose() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Use some resources
        _ = try await pool.withResource { $0.id }
        
        await pool.close()
        
        #if DEBUG
        await pool.testVerifyAccounting()
        #endif
        
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
    }

    @Test("Drain with all resources already available")
    func testDrainWithAvailableResources() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Don't use any resources
        try await pool.drain(timeout: .milliseconds(100))
        
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
    }

    @Test("Close cleans up background tasks")
    func testCloseCleanupBackgroundTasks() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Create some waiters to trigger background cleanup
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await pool.withResource { _ in
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            
            try await Task.sleep(for: .milliseconds(50))
            
            group.addTask {
                do {
                    try await pool.withResource(timeout: .milliseconds(50)) { _ in }
                } catch {
                    // Expected
                }
            }
            
            try await group.waitForAll()
        }
        
        // Close should stop background tasks
        await pool.close()
        
        // No assertions needed - just verify no crashes
    }
}
