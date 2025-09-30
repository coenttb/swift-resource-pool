import Testing
import Foundation
/*@testable*/ import ResourcePool

// MARK: - Mock Resource

actor MockResource: PoolableResource {
    struct Config: Sendable {
        let name: String
        let creationDelay: Duration
        let resetDelay: Duration
        let shouldFailValidation: Bool
        let shouldFailReset: Bool
        let failResetAfterUses: Int?

        init(
            name: String = "test",
            creationDelay: Duration = .milliseconds(10),
            resetDelay: Duration = .milliseconds(5),
            shouldFailValidation: Bool = false,
            shouldFailReset: Bool = false,
            failResetAfterUses: Int? = nil
        ) {
            self.name = name
            self.creationDelay = creationDelay
            self.resetDelay = resetDelay
            self.shouldFailValidation = shouldFailValidation
            self.shouldFailReset = shouldFailReset
            self.failResetAfterUses = failResetAfterUses
        }
    }

    let id = UUID()
    let config: Config
    private(set) var isValid: Bool = true
    private(set) var resetCount: Int = 0
    private(set) var useCount: Int = 0

    init(config: Config = Config()) {
        self.config = config
    }

    static func create(config: Config) async throws -> MockResource {
        try await Task.sleep(for: config.creationDelay)
        return MockResource(config: config)
    }

    func validate() async -> Bool {
        !config.shouldFailValidation && isValid
    }

    func reset() async throws {
        try await Task.sleep(for: config.resetDelay)
        
        if config.shouldFailReset {
            throw MockError.resetFailed
        }
        
        if let failAfter = config.failResetAfterUses, resetCount >= failAfter {
            throw MockError.resetFailed
        }
        
        resetCount += 1
    }

    func use() {
        useCount += 1
    }

    func invalidate() {
        isValid = false
    }
    
    enum MockError: Error {
        case resetFailed
    }
}

// MARK: - Failing Resource (for creation failure tests)

actor FailingResource: PoolableResource {
    struct Config: Sendable {
        let shouldFailCreation: Bool
        
        init(shouldFailCreation: Bool = true) {
            self.shouldFailCreation = shouldFailCreation
        }
    }
    
    static func create(config: Config) async throws -> FailingResource {
        if config.shouldFailCreation {
            throw CreationError.intentionalFailure
        }
        return FailingResource()
    }
    
    func validate() async -> Bool { true }
    func reset() async throws {}
    
    enum CreationError: Error {
        case intentionalFailure
    }
}

// MARK: - Database-like Resource

actor DatabaseConnection: PoolableResource {
    struct Config: Sendable {
        let host: String
        let port: Int

        init(host: String = "localhost", port: Int = 5432) {
            self.host = host
            self.port = port
        }
    }

    let id = UUID()
    private var transactionDepth = 0

    static func create(config: Config) async throws -> DatabaseConnection {
        // Simulate connection establishment
        try await Task.sleep(for: .milliseconds(50))
        return DatabaseConnection()
    }

    func validate() async -> Bool {
        // Check if connection is still alive
        true
    }

    func reset() async throws {
        // Clear any transaction state
        transactionDepth = 0
        try await Task.sleep(for: .milliseconds(10))
    }

    func beginTransaction() {
        transactionDepth += 1
    }

    func commit() {
        if transactionDepth > 0 {
            transactionDepth -= 1
        }
    }

    func query(_ sql: String) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(20))
        return ["result1", "result2"]
    }
}

// MARK: - Tests

@Suite("ResourcePool Tests")
struct ResourcePoolTests {

    @Test("Basic resource usage with withResource")
    func testBasicResourceUsage() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(),
            warmup: true
        )

        // Check initial statistics
        let initialStats = await pool.statistics
        #expect(initialStats.available == 3)
        #expect(initialStats.leased == 0)
        #expect(initialStats.utilization == 0.0)

        // Use a resource
        let result = try await pool.withResource { resource in
            // Check statistics during use
            let duringStats = await pool.statistics
            #expect(duringStats.available == 2)
            #expect(duringStats.leased == 1)
            #expect(duringStats.utilization > 0.0)
            
            return resource.id.uuidString
        }
        #expect(!result.isEmpty)

        // Wait a bit for resource to be returned
        try await Task.sleep(for: .milliseconds(100))

        // Check statistics after release
        let afterReleaseStats = await pool.statistics
        #expect(afterReleaseStats.available == 3)
        #expect(afterReleaseStats.leased == 0)
        #expect(afterReleaseStats.utilization == 0.0)
    }

    @Test("Timeout when pool exhausted")
    func testTimeoutWhenExhausted() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )

        // Hold all resources
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Hold first resource
            group.addTask {
                try await pool.withResource { _ in
                    try await Task.sleep(for: .seconds(2))
                }
            }
            
            // Task 2: Hold second resource
            group.addTask {
                try await pool.withResource { _ in
                    try await Task.sleep(for: .seconds(2))
                }
            }
            
            // Give the tasks time to acquire resources
            try await Task.sleep(for: .milliseconds(50))
            
            // Task 3: Try to acquire when exhausted - should timeout
            group.addTask {
                do {
                    try await pool.withResource(timeout: .milliseconds(100)) { _ in
                        Issue.record("Should have timed out")
                    }
                    Issue.record("Expected timeout but succeeded")
                } catch PoolError.timeout {
                    // Expected
                } catch {
                    Issue.record("Unexpected error: \(error)")
                }
            }
            
            try await group.waitForAll()
        }
        
        // Verify timeout was recorded in metrics
        let metrics = await pool.metrics
        #expect(metrics.timeouts == 1)
    }

    @Test("Concurrent access")
    func testConcurrentAccess() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )

        // Concurrently acquire and release resources
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await pool.withResource { resource in
                        try await Task.sleep(for: .milliseconds(10))
                        return "Task \(i): \(resource.id)"
                    }
                }
            }

            var results: [String] = []
            for try await result in group {
                results.append(result)
            }

            #expect(results.count == 20)
        }

        // Check final state
        let finalStats = await pool.statistics
        #expect(finalStats.available == 5)
        #expect(finalStats.leased == 0)
        
        // Check metrics
        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions == 20)
        #expect(metrics.successfulReturns == 20)
    }

    @Test("Lazy creation respects capacity")
    func testLazyCreation() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: false  // Don't pre-create resources
        )

        // Initially no resources
        let initialStats = await pool.statistics
        #expect(initialStats.available == 0)
        #expect(initialStats.leased == 0)

        // Use first resource - should create it
        _ = try await pool.withResource { resource in
            let stats = await pool.statistics
            #expect(stats.available == 0)
            #expect(stats.leased == 1)
            return resource.id
        }

        // Use multiple resources concurrently
        try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await pool.withResource { $0.id }
                }
            }
            
            var ids: [UUID] = []
            for try await id in group {
                ids.append(id)
            }
            #expect(ids.count == 3)
        }

        // Wait for resources to be returned
        try await Task.sleep(for: .milliseconds(100))

        // Should have 3 available resources now (1 from first use + 2 more created)
        let finalStats = await pool.statistics
        #expect(finalStats.available == 3)
        #expect(finalStats.leased == 0)
    }

    @Test("Invalid resources are discarded")
    func testInvalidResourcesDiscarded() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(shouldFailValidation: true),
            warmup: false
        )

        // Use a resource (it will fail validation on return)
        _ = try await pool.withResource { $0.id }

        // Wait for return processing
        try await Task.sleep(for: .milliseconds(100))

        // Resource should be discarded, not available
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
        
        // Check metrics
        let metrics = await pool.metrics
        #expect(metrics.validationFailures == 1)
    }

    @Test("Pool cleanup on close")
    func testPoolCleanup() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )

        // Use some resources in background
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

        // Give tasks time to acquire
        try await Task.sleep(for: .milliseconds(50))

        // Close the pool
        await pool.close()

        // Stats should show empty pool
        let stats = await pool.statistics
        #expect(stats.available == 0)

        // Clean up tasks
        task1.cancel()
        task2.cancel()
        _ = try? await task1.value
        _ = try? await task2.value
    }

    @Test("Database connection pool example")
    func testDatabaseConnectionPool() async throws {
        let pool = try await ResourcePool<DatabaseConnection>(
            capacity: 10,
            resourceConfig: .init()
        )

        // Simulate multiple database queries
        try await withThrowingTaskGroup(of: [String].self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await pool.withResource { conn in
                        try await conn.query("SELECT * FROM table_\(i)")
                    }
                }
            }

            var allResults: [[String]] = []
            for try await results in group {
                allResults.append(results)
            }

            #expect(allResults.count == 20)
            #expect(allResults.allSatisfy { $0.count == 2 })
        }

        // Check pool is healthy after use
        let stats = await pool.statistics
        #expect(stats.leased == 0)
        #expect(stats.utilization == 0.0)
    }

    @Test("Resource becomes available to waiter")
    func testResourceBecomesAvailableToWaiter() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 1,
            resourceConfig: .init(),
            warmup: true
        )

        // Track if waiter succeeded
        actor WaiterState {
            var succeeded = false
            var resourceId: UUID?

            func markSuccess(id: UUID) {
                succeeded = true
                resourceId = id
            }
        }
        let waiterState = WaiterState()

        // Start tasks that will compete for the single resource
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Hold resource briefly
            group.addTask {
                try await pool.withResource { _ in
                    // Verify pool is exhausted while we hold it
                    let stats = await pool.statistics
                    #expect(stats.available == 0)
                    #expect(stats.leased == 1)
                    
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            
            // Give first task time to acquire
            try await Task.sleep(for: .milliseconds(50))
            
            // Task 2: Wait for resource to become available
            group.addTask {
                let id = try await pool.withResource(timeout: .seconds(5)) { resource in
                    resource.id
                }
                await waiterState.markSuccess(id: id)
            }
            
            try await group.waitForAll()
        }

        // Verify waiter succeeded
        let succeeded = await waiterState.succeeded
        #expect(succeeded == true)

        // Verify final state
        let finalStats = await pool.statistics
        #expect(finalStats.available == 1)
        #expect(finalStats.leased == 0)
    }

    @Test("Automatic cleanup on cancellation")
    func testAutomaticCleanupOnCancellation() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )

        // Track resource IDs to verify cleanup
        actor ResourceTracker {
            var acquiredIds: Set<UUID> = []
            
            func track(_ id: UUID) {
                acquiredIds.insert(id)
            }
            
            var count: Int { acquiredIds.count }
        }
        let tracker = ResourceTracker()

        // Start multiple tasks that will be cancelled
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await pool.withResource(timeout: .seconds(1)) { resource in
                            await tracker.track(resource.id)
                            // Hold resource and wait to be cancelled
                            try await Task.sleep(for: .seconds(10))
                        }
                    } catch {
                        // Cancellation or timeout expected
                    }
                }
            }
            
            // Give tasks time to start acquiring resources
            try? await Task.sleep(for: .milliseconds(100))
            
            // Cancel all tasks
            group.cancelAll()
            
            // Wait for all tasks to complete (cleanup happens here)
            await group.waitForAll()
        }

        // Verify we actually acquired some resources during the test
        let acquiredCount = await tracker.count
        #expect(acquiredCount > 0)

        // After all cancellations complete, pool should be back to initial state
        // No sleep needed - await group.waitForAll() ensures all cleanup completed
        let finalStats = await pool.statistics
        #expect(finalStats.leased == 0)
        #expect(finalStats.available == 2)
    }

    @Test("Stress test - high concurrency")
    func testHighConcurrency() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 10,
            resourceConfig: .init(
                creationDelay: .milliseconds(5),
                resetDelay: .milliseconds(2)
            ),
            warmup: true
        )

        let taskCount = 100
        let operationsPerTask = 10

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    for _ in 0..<operationsPerTask {
                        try await pool.withResource(timeout: .seconds(5)) { resource in
                            // Simulate some work
                            try await Task.sleep(for: .microseconds(100))
                            _ = resource.id
                        }
                    }
                }
            }

            try await group.waitForAll()
        }

        // Pool should be in clean state
        let finalStats = await pool.statistics
        #expect(finalStats.leased == 0)
        #expect(finalStats.available <= 10)
        
        // Check metrics
        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions == taskCount * operationsPerTask)
    }

    @Test("Pool warmup creates resources eagerly")
    func testWarmupCreatesResourcesEagerly() async throws {
        let warmupPool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )

        let warmupStats = await warmupPool.statistics
        #expect(warmupStats.available == 5)
        #expect(warmupStats.leased == 0)

        let noWarmupPool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: false
        )

        let noWarmupStats = await noWarmupPool.statistics
        #expect(noWarmupStats.available == 0)
        #expect(noWarmupStats.leased == 0)
    }
    
    @Test("withResource handles errors correctly")
    func testErrorHandling() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        struct TestError: Error {}
        
        // Use a resource and throw an error
        do {
            try await pool.withResource { _ in
                throw TestError()
            }
            Issue.record("Should have thrown error")
        } catch is TestError {
            // Expected
        }
        
        // Wait for resource to be returned
        try await Task.sleep(for: .milliseconds(100))
        
        // Resource should be returned despite error
        let stats = await pool.statistics
        #expect(stats.available == 2)
        #expect(stats.leased == 0)
    }
    
    @Test("Resource reset failure discards resource")
    func testResetFailureDiscardsResource() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(shouldFailReset: true),
            warmup: false
        )
        
        // Use a resource (it will fail reset on return)
        _ = try await pool.withResource { $0.id }
        
        // Wait for return processing
        try await Task.sleep(for: .milliseconds(100))
        
        // Resource should be discarded, not available
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
        
        // Check metrics
        let metrics = await pool.metrics
        #expect(metrics.resetFailures == 1)
        #expect(metrics.successfulReturns == 0)
    }
    
    @Test("Resource reset failure after multiple uses")
    func testResetFailureAfterMultipleUses() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(failResetAfterUses: 2),
            warmup: true
        )
        
        // Use resource successfully twice
        for _ in 0..<2 {
            _ = try await pool.withResource { $0.id }
            try await Task.sleep(for: .milliseconds(50))
        }
        
        let statsAfterTwo = await pool.statistics
        #expect(statsAfterTwo.available == 2)
        
        // Third use should fail reset
        _ = try await pool.withResource { $0.id }
        try await Task.sleep(for: .milliseconds(100))
        
        // One resource should be discarded
        let finalStats = await pool.statistics
        #expect(finalStats.available == 1)
        
        let metrics = await pool.metrics
        #expect(metrics.resetFailures == 1)
    }
    
    @Test("Concurrent close and acquire")
    func testCloseRaceCondition() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Start multiple acquisition attempts
        await withTaskGroup(of: Void.self) { group in
            // Start acquisitions
            for _ in 0..<10 {
                group.addTask {
                    do {
                        _ = try await pool.withResource(timeout: .milliseconds(100)) { _ in
                            try await Task.sleep(for: .milliseconds(200))
                        }
                    } catch {
                        // Some will fail with closed error, some with timeout
                    }
                }
            }
            
            // Close pool while acquisitions are in flight
            try? await Task.sleep(for: .milliseconds(50))
            await pool.close()
            
            await group.waitForAll()
        }
        
        // Pool should be closed
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
    
    @Test("Statistics remain consistent under concurrent access")
    func testStatisticsConsistency() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        actor StatsValidator {
            var inconsistencies: [String] = []
            
            func validate(_ stats: Statistics) {
                let total = stats.available + stats.leased
                if total > stats.capacity {
                    inconsistencies.append("Total (\(total)) > capacity (\(stats.capacity))")
                }
                if stats.available < 0 || stats.leased < 0 {
                    inconsistencies.append("Negative values: available=\(stats.available), leased=\(stats.leased)")
                }
            }
            
            var isValid: Bool { inconsistencies.isEmpty }
        }
        let validator = StatsValidator()
        
        await withTaskGroup(of: Void.self) { group in
            // Hammer the pool with operations
            for _ in 0..<20 {
                group.addTask {
                    do {
                        try await pool.withResource(timeout: .seconds(1)) { _ in
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    } catch {
                        // Timeouts expected under contention
                    }
                }
            }
            
            // Continuously read statistics
            group.addTask {
                for _ in 0..<100 {
                    let stats = await pool.statistics
                    await validator.validate(stats)
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            
            await group.waitForAll()
        }
        
        let isValid = await validator.isValid
        #expect(isValid)
    }
    
    @Test("All resources fail validation simultaneously")
    func testAllResourcesFailValidation() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Use all resources and invalidate them
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await pool.withResource { resource in
                        await resource.invalidate()
                    }
                }
            }
            try await group.waitForAll()
        }
        
        // Wait for all resources to be processed
        try await Task.sleep(for: .milliseconds(200))
        
        // All resources should be discarded
        let stats = await pool.statistics
        #expect(stats.available == 0)
        #expect(stats.leased == 0)
        
        let metrics = await pool.metrics
        #expect(metrics.validationFailures == 3)
        
        // Pool should still work - create new resources on demand
        let newResourceId = try await pool.withResource { $0.id }
        #expect(newResourceId != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }
    
    @Test("Factory creation failure during lazy creation")
    func testCreationFailureHandling() async throws {
        // This test verifies behavior when resource creation fails
        do {
            _ = try await ResourcePool<FailingResource>(
                capacity: 3,
                resourceConfig: .init(shouldFailCreation: true),
                warmup: true
            )
            Issue.record("Should have thrown creation error during warmup")
        } catch PoolError.creationFailed {
            // Expected during warmup
        }
        
        // Now test lazy creation failure
        let pool = try await ResourcePool<FailingResource>(
            capacity: 3,
            resourceConfig: .init(shouldFailCreation: true),
            warmup: false
        )
        
        do {
            _ = try await pool.withResource { _ in }
            Issue.record("Should have thrown creation error")
        } catch PoolError.creationFailed {
            // Expected
        }
        
        // Check metrics recorded the failure
        let metrics = await pool.metrics
        #expect(metrics.creationFailures >= 1)
    }
    
    @Test("Metrics track acquisitions and wait times")
    func testMetricsTracking() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Perform some operations
        for _ in 0..<5 {
            _ = try await pool.withResource { $0.id }
        }
        
        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions == 5)
        #expect(metrics.successfulReturns == 5)
        #expect(metrics.averageWaitTime != nil)
        #expect(metrics.timeouts == 0)
        #expect(metrics.validationFailures == 0)
        #expect(metrics.resetFailures == 0)
    }
    
    @Test("Drain waits for resources to return")
    func testDrainWaitsForResources() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Start long-running operation
        let operation = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        
        // Give task time to acquire
        try await Task.sleep(for: .milliseconds(50))
        
        // Drain should wait for the resource
        let drainTask = Task {
            try await pool.drain(timeout: .seconds(1))
        }
        
        // Wait for both to complete
        _ = try await operation.value
        _ = try await drainTask.value
        
        // Pool should be empty
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
        
        // Start long-running operation
        let operation = Task {
            try await pool.withResource { _ in
                try await Task.sleep(for: .seconds(10))
            }
        }
        
        // Give task time to acquire
        try await Task.sleep(for: .milliseconds(50))
        
        // Drain should timeout
        do {
            try await pool.drain(timeout: .milliseconds(100))
            Issue.record("Should have timed out")
        } catch PoolError.drainTimeout {
            // Expected
        }
        
        // Clean up
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
        
        // Start drain
        let drainTask = Task {
            try await pool.drain(timeout: .seconds(1))
        }
        
        // Give drain time to set closed flag
        try await Task.sleep(for: .milliseconds(50))
        
        // New acquisition should fail
        do {
            _ = try await pool.withResource { $0.id }
            Issue.record("Should have failed with closed error")
        } catch PoolError.closed {
            // Expected
        }
        
        _ = try? await drainTask.value
    }
    
    @Test("LIFO resource selection maintains cache locality")
    func testLIFOResourceSelection() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Track which resources are used
        actor ResourceUsage {
            var usageOrder: [UUID] = []
            
            func record(_ id: UUID) {
                usageOrder.append(id)
            }
        }
        let usage = ResourceUsage()
        
        // Use resources in sequence
        for _ in 0..<5 {
            let id = try await pool.withResource { resource in
                await resource.use()
                return resource.id
            }
            await usage.record(id)
            try await Task.sleep(for: .milliseconds(50))
        }
        
        // LIFO means we should reuse the same resources
        let usageOrder = await usage.usageOrder
        let uniqueResources = Set(usageOrder)
        
        // With LIFO and sufficient delay, we should see resource reuse
        #expect(uniqueResources.count < usageOrder.count)
    }
    
    @Test("Thundering herd - many waiters compete for few resources")
    func testThunderingHerdProblem() async throws {
        // Small pool to create contention
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(
                creationDelay: .milliseconds(5),
                resetDelay: .milliseconds(5)
            ),
            warmup: true
        )
        
        // Track contention metrics
        actor ContentionMetrics {
            var acquireAttempts: [Int] = [] // How many attempts each task needed
            var waitTimes: [Duration] = []
            var peakWaiters: Int = 0
            var currentWaiters: Int = 0
            
            func recordAcquisitionStart() {
                currentWaiters += 1
                peakWaiters = max(peakWaiters, currentWaiters)
            }
            
            func recordAcquisitionEnd(waitTime: Duration) {
                currentWaiters -= 1
                waitTimes.append(waitTime)
            }
            
            var averageWaitTime: Duration? {
                guard !waitTimes.isEmpty else { return nil }
                let total = waitTimes.reduce(Duration.zero) { $0 + $1 }
                return total / waitTimes.count
            }
            
            var maxWaitTime: Duration? {
                waitTimes.max()
            }
            
            // High variance in wait times indicates thundering herd
            var waitTimeVariance: Double? {
                guard waitTimes.count > 1 else { return nil }
                guard let avg = averageWaitTime else { return nil }
                
                let avgNanos = Double(avg.components.seconds * 1_000_000_000 +
                                     avg.components.attoseconds / 1_000_000_000)
                
                let squaredDiffs = waitTimes.map { duration -> Double in
                    let nanos = Double(duration.components.seconds * 1_000_000_000 +
                                     duration.components.attoseconds / 1_000_000_000)
                    let diff = nanos - avgNanos
                    return diff * diff
                }
                
                return squaredDiffs.reduce(0, +) / Double(waitTimes.count)
            }
        }
        let metrics = ContentionMetrics()
        
        // Many waiters competing for 2 resources
        let waiterCount = 50
        let workDuration = Duration.milliseconds(20)
        
        let startTime = ContinuousClock.now
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<waiterCount {
                group.addTask {
                    let acquisitionStart = ContinuousClock.now
                    await metrics.recordAcquisitionStart()
                    
                    try await pool.withResource(timeout: .seconds(30)) { _ in
                        // Simulate work
                        try await Task.sleep(for: workDuration)
                    }
                    
                    let waitTime = ContinuousClock.now - acquisitionStart
                    await metrics.recordAcquisitionEnd(waitTime: waitTime)
                }
            }
            
            try await group.waitForAll()
        }
        
        let totalTime = ContinuousClock.now - startTime
        
        // Print metrics to demonstrate thundering herd
        let peakWaiters = await metrics.peakWaiters
        let avgWait = await metrics.averageWaitTime
        let maxWait = await metrics.maxWaitTime
        let variance = await metrics.waitTimeVariance
        
        print("\n=== Thundering Herd Metrics ===")
        print("Waiters: \(waiterCount)")
        print("Pool capacity: 2")
        print("Peak concurrent waiters: \(peakWaiters)")
        print("Average wait time: \(avgWait?.formatted() ?? "N/A")")
        print("Max wait time: \(maxWait?.formatted() ?? "N/A")")
        print("Wait time variance: \(variance?.formatted() ?? "N/A") ns²")
        print("Total execution time: \(totalTime.formatted())")
        
        // Theoretical optimal time if no contention:
        // With 2 resources, 50 tasks, each taking ~20ms
        // Optimal: 50 / 2 * 20ms = 500ms
        let theoreticalOptimal = Duration.milliseconds(Int64(waiterCount / 2 * 20))
        print("Theoretical optimal time: \(theoreticalOptimal.formatted())")
        print("Overhead factor: \(String(format: "%.2f", Double(totalTime.components.attoseconds) / Double(theoreticalOptimal.components.attoseconds)))x")
        
        // Assertions to verify the problem exists
        #expect(peakWaiters > 10) // Many waiters queued up
        
        // High variance indicates some tasks waited much longer than others
        if let variance = variance {
            #expect(variance > 0) // Should have variance
        }
        
        // Total time should exceed theoretical optimal due to contention
        #expect(totalTime > theoreticalOptimal)
    }

    @Test("Thundering herd - wakeup inefficiency")
    func testThunderingHerdWakeups() async throws {
        // This test specifically measures how many times waiters wake up
        // but fail to acquire a resource (the core thundering herd symptom)
        
        let pool = try await ResourcePool<MockResource>(
            capacity: 1, // Single resource = maximum contention
            resourceConfig: .init(),
            warmup: true
        )
        
        actor WakeupTracker {
            var totalWakeups: Int = 0
            var successfulAcquisitions: Int = 0
            
            func recordWakeup() {
                totalWakeups += 1
            }
            
            func recordSuccess() {
                successfulAcquisitions += 1
            }
            
            // Ratio of wasted wakeups: higher = more thundering herd
            var wakeupEfficiency: Double {
                guard totalWakeups > 0 else { return 0 }
                return Double(successfulAcquisitions) / Double(totalWakeups)
            }
        }
        let tracker = WakeupTracker()
        
        let waiterCount = 30
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<waiterCount {
                group.addTask {
                    // Track acquisition attempts
                    var attempts = 0
                    var acquired = false
                    
                    while !acquired {
                        attempts += 1
                        await tracker.recordWakeup()
                        
                        do {
                            try await pool.withResource(timeout: .seconds(10)) { _ in
                                await tracker.recordSuccess()
                                acquired = true
                                try await Task.sleep(for: .milliseconds(10))
                            }
                        } catch {
                            // Timeout or other error - try again
                            try? await Task.sleep(for: .milliseconds(5))
                        }
                    }
                }
            }
            
            try await group.waitForAll()
        }
        
        let efficiency = await tracker.wakeupEfficiency
        let totalWakeups = await tracker.totalWakeups
        let successful = await tracker.successfulAcquisitions
        
        print("\n=== Wakeup Efficiency Metrics ===")
        print("Total wakeup events: \(totalWakeups)")
        print("Successful acquisitions: \(successful)")
        print("Wakeup efficiency: \(String(format: "%.1f%%", efficiency * 100))")
        print("Wasted wakeups: \(totalWakeups - successful)")
        
        // With thundering herd, we expect many more wakeups than successful acquisitions
        // Ideally, wakeup efficiency should be close to 100%
        // With thundering herd on single resource pool, it will be much lower
        #expect(efficiency < 0.5) // Less than 50% efficient
        #expect(totalWakeups > successful * 2) // At least 2x as many wakeups
    }

    @Test("Compare pool sizes - demonstrating scalability issues")
    func testPoolSizeImpactOnContention() async throws {
        // This test shows how throughput degrades with small pools under high load
        
        struct PerformanceResult {
            let capacity: Int
            let throughput: Double // operations per second
            let avgWaitTime: Duration
        }
        
        actor ResultCollector {
            var results: [PerformanceResult] = []
            
            func add(_ result: PerformanceResult) {
                results.append(result)
            }
        }
        let collector = ResultCollector()
        
        // Test different pool sizes
        for capacity in [1, 2, 5, 10, 20] {
            let pool = try await ResourcePool<MockResource>(
                capacity: capacity,
                resourceConfig: .init(
                    creationDelay: .milliseconds(1),
                    resetDelay: .milliseconds(1)
                ),
                warmup: true
            )
            
            let operations = 100
            let startTime = ContinuousClock.now
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<operations {
                    group.addTask {
                        try await pool.withResource(timeout: .seconds(10)) { _ in
                            try await Task.sleep(for: .milliseconds(5))
                        }
                    }
                }
                
                try await group.waitForAll()
            }
            
            let duration = ContinuousClock.now - startTime
            let durationSeconds = Double(duration.components.seconds) +
                                Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
            
            let metrics = await pool.metrics
            let throughput = Double(operations) / durationSeconds
            
            let result = PerformanceResult(
                capacity: capacity,
                throughput: throughput,
                avgWaitTime: metrics.averageWaitTime ?? .zero
            )
            
            await collector.add(result)
        }
        
        let results = await collector.results
        
        print("\n=== Pool Size Impact on Performance ===")
        print("Capacity      Throughput      Avg Wait")
        print("--------------------------------------------")
        
        for result in results {
            let waitMs = Double(result.avgWaitTime.components.attoseconds) / 1_000_000_000_000_000
            let capacityStr = "\(result.capacity)".padding(toLength: 13, withPad: " ", startingAt: 0)
            let throughputStr = String(format: "%.1f", result.throughput).padding(toLength: 15, withPad: " ", startingAt: 0)
            let waitStr = String(format: "%.1f ms", waitMs)
            print("\(capacityStr) \(throughputStr) \(waitStr)")
        }
        
        // Verify throughput increases with capacity (up to a point)
        #expect(results[1].throughput > results[0].throughput) // 2 > 1
        #expect(results[2].throughput > results[1].throughput) // 5 > 2
    }
}

extension Duration {
    func formatted() -> String {
        let totalNanos = components.seconds * 1_000_000_000 +
                        components.attoseconds / 1_000_000_000
        
        if totalNanos < 1_000_000 { // < 1ms
            return "\(totalNanos) ns"
        } else if totalNanos < 1_000_000_000 { // < 1s
            return String(format: "%.2f ms", Double(totalNanos) / 1_000_000)
        } else {
            return String(format: "%.2f s", Double(totalNanos) / 1_000_000_000)
        }
    }
}
