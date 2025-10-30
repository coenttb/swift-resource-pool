import Testing
import Foundation
@testable import ResourcePool

/// Tests verifying that code examples in README.md compile and execute correctly
@Suite("README Verification Tests")
struct ReadmeVerificationTests {

    // MARK: - Overview Section (Lines 24-60)

    @Test("Overview: Basic DatabaseConnection example compiles")
    func overviewBasicExample() async throws {
        // Define your poolable resource
        actor DatabaseConnection: PoolableResource {
            struct Config: Sendable {
                let host: String
                let port: Int
            }

            static func create(config: Config) async throws -> DatabaseConnection {
                // Create and return connection
                return DatabaseConnection()
            }

            func validate() async -> Bool {
                // Check if connection is still alive
                return true
            }

            func reset() async throws {
                // Reset connection state for reuse
            }

            func query(_ sql: String) async throws -> [String] {
                return ["result"]
            }
        }

        // Create a pool with 10 connections
        let pool = try await ResourcePool<DatabaseConnection>(
            capacity: 10,
            resourceConfig: .init(host: "localhost", port: 5432),
            warmup: true
        )

        // Use resources safely with automatic cleanup
        let results = try await pool.withResource { connection in
            try await connection.query("SELECT * FROM users")
        }

        #expect(!results.isEmpty)
    }

    // MARK: - Quick Start Section (Lines 105-146)

    @Test("Quick Start: SimpleResource example compiles")
    func quickStartSimpleResource() async throws {
        // Simple mock resource for demonstration
        actor SimpleResource: PoolableResource {
            struct Config: Sendable {
                let name: String
            }

            let id = UUID()
            private var useCount = 0

            static func create(config: Config) async throws -> SimpleResource {
                return SimpleResource()
            }

            func validate() async -> Bool {
                return true
            }

            func reset() async throws {
                // Reset any state
            }

            func use() {
                useCount += 1
            }
        }

        // Create pool
        let pool = try await ResourcePool<SimpleResource>(
            capacity: 5,
            resourceConfig: .init(name: "my-resource"),
            warmup: true
        )

        // Use resource with automatic cleanup
        let result = try await pool.withResource(timeout: .seconds(10)) { resource in
            await resource.use()
            return "Success"
        }

        #expect(result == "Success")
    }

    // MARK: - Core Concepts Section (Lines 148-207)

    @Test("Core Concepts: PoolableResource protocol compiles")
    func coreConceptsProtocol() async throws {
        // Verify protocol exists with correct shape
        actor TestResource: PoolableResource {
            struct Config: Sendable {}

            static func create(config: Config) async throws -> TestResource {
                return TestResource()
            }

            func validate() async -> Bool {
                return true
            }

            func reset() async throws {
                // Reset
            }
        }

        let pool = try await ResourcePool<TestResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: false
        )

        _ = try await pool.withResource { _ in
            return "OK"
        }
    }

    @Test("Core Concepts: Statistics API compiles")
    func coreConceptsStatistics() async throws {
        actor MockResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockResource { MockResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
        }

        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: false
        )

        let stats = await pool.statistics
        #expect(stats.available >= 0)
        #expect(stats.leased >= 0)
        #expect(stats.utilization >= 0.0 && stats.utilization <= 1.0)
        #expect(stats.waitQueueDepth >= 0)

        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions >= 0)
        #expect(metrics.timeouts >= 0)
        #expect(metrics.handoffRate >= 0.0 && metrics.handoffRate <= 1.0)
    }

    // MARK: - Advanced Usage Section (Lines 489-560)

    @Test("Advanced Usage: Unreliable resource handling compiles")
    func advancedUsageUnreliableResource() async throws {
        // Resource that can fail validation
        actor UnreliableResource: PoolableResource {
            struct Config: Sendable {}
            private var failureCount = 0

            static func create(config: Config) async throws -> UnreliableResource {
                return UnreliableResource()
            }

            func validate() async -> Bool {
                // Simulate intermittent failures
                failureCount += 1
                return failureCount % 5 != 0
            }

            func reset() async throws {}

            // Pool automatically discards invalid resources
        }

        let pool = try await ResourcePool<UnreliableResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: false
        )

        // Pool handles validation failures gracefully
        _ = try await pool.withResource { _ in
            return "OK"
        }
    }

    @Test("Advanced Usage: Custom timeouts compile")
    func advancedUsageCustomTimeouts() async throws {
        actor MockResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockResource { MockResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
            func quickOperation() async throws -> String { "quick" }
            func expensiveOperation() async throws -> String { "expensive" }
        }

        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )

        // Short timeout for quick operations
        let fastResult = try await pool.withResource(timeout: .seconds(1)) { resource in
            try await resource.quickOperation()
        }
        #expect(fastResult == "quick")

        // Long timeout for expensive operations
        let slowResult = try await pool.withResource(timeout: .seconds(60)) { resource in
            try await resource.expensiveOperation()
        }
        #expect(slowResult == "expensive")
    }

    @Test("Advanced Usage: Graceful shutdown compiles")
    func advancedUsageGracefulShutdown() async throws {
        actor MockResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockResource { MockResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
        }

        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )

        // Application shutdown
        func shutdown() async throws {
            do {
                // Wait for active operations to complete
                try await pool.drain(timeout: .seconds(30))
                // Pool drained successfully
            } catch PoolError.drainTimeout {
                // Pool drain timed out, some resources still leased
                // Force close if needed
                await pool.close()
            }
        }

        try await shutdown()
    }

    @Test("Advanced Usage: Global actor pool sharing pattern compiles")
    func advancedUsageGlobalActorPool() async throws {
        actor MockWebViewResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockWebViewResource { MockWebViewResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
            func renderPDF(html: String) async throws -> Data { Data() }
        }

        // ✅ GOOD: Single shared pool via global actor
        @globalActor
        actor WebViewPoolActor {
            static let shared = WebViewPoolActor()

            private var sharedPool: ResourcePool<MockWebViewResource>?

            func getPool() async throws -> ResourcePool<MockWebViewResource> {
                if let existing = sharedPool {
                    return existing
                }

                let pool = try await ResourcePool<MockWebViewResource>(
                    capacity: 8,
                    resourceConfig: .init(),
                    warmup: true
                )
                sharedPool = pool
                return pool
            }
        }

        // Usage: All callers share the same pool
        func generatePDF(html: String) async throws -> Data {
            let pool = try await WebViewPoolActor.shared.getPool()
            return try await pool.withResource { webView in
                try await webView.renderPDF(html: html)
            }
        }

        let result = try await generatePDF(html: "<html></html>")
        #expect(result.isEmpty)
    }

    // MARK: - Error Handling Section (Lines 631-640)

    @Test("Error Handling: PoolError cases compile")
    func errorHandlingPoolError() async throws {
        // Verify all error cases exist
        let errors: [PoolError] = [
            .timeout,
            .closed,
            .creationFailed("test"),
            .resetFailed("test"),
            .drainTimeout
        ]

        #expect(errors.count == 5)

        // Verify error conformances
        for error in errors {
            _ = error as Error
            _ = error as Sendable
            _ = error as any Equatable
        }
    }

    // MARK: - API Reference Section (Lines 416-487)

    @Test("API Reference: Initialization parameters compile")
    func apiReferenceInit() async throws {
        actor MockResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockResource { MockResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
        }

        // Test all init parameters
        let poolWithWarmup = try await ResourcePool<MockResource>(
            capacity: 10,
            resourceConfig: .init(),
            warmup: true
        )

        let poolWithoutWarmup = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: false
        )

        #expect(await poolWithWarmup.statistics.capacity == 10)
        #expect(await poolWithoutWarmup.statistics.capacity == 5)
    }

    @Test("API Reference: Core methods compile")
    func apiReferenceCoreMethods() async throws {
        actor MockResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockResource { MockResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
        }

        let pool = try await ResourcePool<MockResource>(
            capacity: 2,
            resourceConfig: .init(),
            warmup: true
        )

        // withResource
        let _ = try await pool.withResource(timeout: .seconds(30)) { _ in
            return "result"
        }

        // statistics
        let stats = await pool.statistics
        #expect(stats.capacity == 2)

        // metrics
        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions >= 0)

        // drain and close
        try await pool.drain(timeout: .seconds(30))
        await pool.close()
    }

    @Test("API Reference: Statistics struct compiles")
    func apiReferenceStatistics() async throws {
        actor MockResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockResource { MockResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
        }

        let pool = try await ResourcePool<MockResource>(
            capacity: 10,
            resourceConfig: .init(),
            warmup: true
        )

        let stats = await pool.statistics

        // Verify all properties exist
        _ = stats.available
        _ = stats.leased
        _ = stats.capacity
        _ = stats.waitQueueDepth
        _ = stats.inUse  // Alias for leased
        _ = stats.utilization  // 0.0 to 1.0
        _ = stats.hasBackpressure  // Queue depth > 0

        #expect(stats.inUse == stats.leased)
    }

    @Test("API Reference: Metrics struct compiles")
    func apiReferenceMetrics() async throws {
        actor MockResource: PoolableResource {
            struct Config: Sendable {}
            static func create(config: Config) async throws -> MockResource { MockResource() }
            func validate() async -> Bool { true }
            func reset() async throws {}
        }

        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )

        let metrics = await pool.metrics

        // Verify all properties exist
        _ = metrics.currentStatistics
        _ = metrics.totalAcquisitions
        _ = metrics.timeouts
        _ = metrics.validationFailures
        _ = metrics.resetFailures
        _ = metrics.creationFailures
        _ = metrics.successfulReturns
        _ = metrics.waitersQueued
        _ = metrics.directHandoffs
        _ = metrics.averageWaitTime
        _ = metrics.handoffRate

        #expect(metrics.handoffRate >= 0.0 && metrics.handoffRate <= 1.0)
    }
}
