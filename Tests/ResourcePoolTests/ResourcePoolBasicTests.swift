import Testing
import Foundation
@testable import ResourcePool

@Suite("ResourcePool - Basic Functionality")
struct ResourcePoolBasicTests {

    @Test("Basic resource usage with withResource")
    func testBasicResourceUsage() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 3,
            resourceConfig: .init(),
            warmup: true
        )

        // Wait for background warmup to complete
        try await pool.waitForWarmupCompletion()

        let initialStats = await pool.statistics
        #expect(initialStats.available == 3)
        #expect(initialStats.leased == 0)
        #expect(initialStats.utilization == 0.0)
        #expect(initialStats.waitQueueDepth == 0)

        let result = try await pool.withResource { resource in
            let duringStats = await pool.statistics
            #expect(duringStats.available == 2)
            #expect(duringStats.leased == 1)
            #expect(duringStats.utilization > 0.0)

            return resource.id.uuidString
        }
        #expect(!result.isEmpty)

        try await Task.sleep(for: .milliseconds(100))

        let afterStats = await pool.statistics
        #expect(afterStats.available == 3)
        #expect(afterStats.leased == 0)
        #expect(afterStats.utilization == 0.0)
    }

    @Test("Pool warmup creates resources eagerly")
    func testWarmupCreatesResourcesEagerly() async throws {
        let warmupPool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )

        // Wait for background warmup to complete
        try await warmupPool.waitForWarmupCompletion()

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

    @Test("Lazy creation respects capacity")
    func testLazyCreation() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: false
        )

        let initialStats = await pool.statistics
        #expect(initialStats.available == 0)
        #expect(initialStats.leased == 0)

        _ = try await pool.withResource { resource in
            let stats = await pool.statistics
            #expect(stats.available == 0)
            #expect(stats.leased == 1)
            return resource.id
        }

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

        try await Task.sleep(for: .milliseconds(100))

        let finalStats = await pool.statistics
        #expect(finalStats.available == 3)
        #expect(finalStats.leased == 0)
    }

    @Test("Statistics show utilization correctly")
    func testUtilizationMetric() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 10,
            resourceConfig: .init(),
            warmup: true
        )
        
        actor UtilizationTracker {
            var observations: [Double] = []
            
            func record(_ util: Double) {
                observations.append(util)
            }
            
            var sawTargetRange: Bool {
                observations.contains { $0 >= 0.4 && $0 <= 0.6 }
            }
        }
        let tracker = UtilizationTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Launch 5 tasks that hold resources
            for _ in 0..<5 {
                group.addTask {
                    try await pool.withResource { _ in
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
            
            // Monitoring task to sample utilization
            group.addTask {
                for _ in 0..<15 {
                    try await Task.sleep(for: .milliseconds(20))
                    let stats = await pool.statistics
                    await tracker.record(stats.utilization)
                }
            }
            
            try await group.waitForAll()
        }

        // Verify we saw the target utilization range
        let sawTargetRange = await tracker.sawTargetRange
        #expect(sawTargetRange, "Should have observed utilization in range 0.4-0.6")
        
        try await Task.sleep(for: .milliseconds(100))
        let finalStats = await pool.statistics
        #expect(finalStats.utilization == 0.0)
    }

    @Test("Metrics track acquisitions correctly")
    func testMetricsTracking() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        for _ in 0..<5 {
            _ = try await pool.withResource { $0.id }
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions == 5)
        #expect(metrics.successfulReturns == 5)
        #expect(metrics.averageWaitTime != nil)
        #expect(metrics.timeouts == 0)
        #expect(metrics.validationFailures == 0)
        #expect(metrics.resetFailures == 0)
    }

    @Test("Database connection pool example")
    func testDatabaseConnectionPool() async throws {
        let pool = try await ResourcePool<DatabaseConnection>(
            capacity: 10,
            resourceConfig: .init()
        )

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

        let stats = await pool.statistics
        #expect(stats.leased == 0)
        #expect(stats.utilization == 0.0)
    }

    @Test("withResource handles errors correctly")
    func testErrorHandling() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        struct TestError: Error {}
        
        do {
            try await pool.withResource { _ in
                throw TestError()
            }
            Issue.record("Should have thrown error")
        } catch is TestError {
            // Expected
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        let stats = await pool.statistics
        #expect(stats.available == 2)
        #expect(stats.leased == 0)
    }

    @Test("Multiple sequential uses work correctly")
    func testSequentialUses() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 1,
            resourceConfig: .init(),
            warmup: true
        )
        
        var usedIds: [UUID] = []
        
        for _ in 0..<10 {
            let id = try await pool.withResource { resource in
                await resource.use()
                return resource.id
            }
            usedIds.append(id)
            try await Task.sleep(for: .milliseconds(20))
        }
        
        // With capacity 1, should reuse the same resource
        let uniqueIds = Set(usedIds)
        #expect(uniqueIds.count == 1)
        
        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions == 10)
    }

    @Test("HasBackpressure indicator works")
    func testBackpressureIndicator() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )

        // Wait for background warmup to complete
        try await pool.waitForWarmupCompletion()

        actor BackpressureTracker {
            var sawBackpressure = false

            func recordBackpressure() {
                sawBackpressure = true
            }
        }
        let tracker = BackpressureTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Hold all resources
            for _ in 0..<2 {
                group.addTask {
                    try await pool.withResource { _ in
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(50))

            // Try to acquire when exhausted
            group.addTask {
                try await pool.withResource(timeout: .seconds(1)) { _ in
                    // Should eventually succeed
                }
            }

            // Check for backpressure
            try await Task.sleep(for: .milliseconds(50))
            let stats = await pool.statistics
            if stats.hasBackpressure {
                await tracker.recordBackpressure()
            }

            try await group.waitForAll()
        }

        let sawBackpressure = await tracker.sawBackpressure
        #expect(sawBackpressure)
    }

    @Test("Handoff rate metric tracks direct handoffs")
    func testHandoffRateMetric() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )
        
        // Create sustained load to trigger direct handoffs
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await pool.withResource(timeout: .seconds(5)) { _ in
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            try await group.waitForAll()
        }
        
        let metrics = await pool.metrics
        #expect(metrics.directHandoffs > 0)
        #expect(metrics.handoffRate > 0.0)
        #expect(metrics.handoffRate <= 1.0)
    }
}
