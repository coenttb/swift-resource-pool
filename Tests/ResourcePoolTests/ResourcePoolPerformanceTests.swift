import Testing
import Foundation
@testable import ResourcePool

@Suite("ResourcePool - Performance & Benchmarks")
struct ResourcePoolPerformanceTests {

    @Test("Stress test - 500 concurrent operations")
    func stressTest() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 20,
            resourceConfig: .init(
                creationDelay: .milliseconds(1),
                resetDelay: .milliseconds(1)
            ),
            warmup: true
        )
        
        let totalOps = 500
        let start = ContinuousClock.now
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<totalOps {
                group.addTask {
                    try await pool.withResource(timeout: .seconds(30)) { _ in
                        let workDuration = (i % 3 == 0) ? 5 : 10
                        try await Task.sleep(for: .milliseconds(workDuration))
                    }
                }
            }
            
            try await group.waitForAll()
        }
        
        let duration = ContinuousClock.now - start
        let metrics = await pool.metrics
        
        print("\n=== STRESS TEST RESULTS ===")
        print("Total operations: \(totalOps)")
        print("Duration: \(duration.formatted())")
        print("Ops/sec: \(String(format: "%.1f", Double(totalOps) / (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)))")
        print("Timeouts: \(metrics.timeouts)")
        print("Failures: creation=\(metrics.creationFailures) validation=\(metrics.validationFailures) reset=\(metrics.resetFailures)")
        
        let finalStats = await pool.statistics
        print("\nFinal state:")
        print("  Available: \(finalStats.available)")
        print("  Leased: \(finalStats.leased)")
        print("  Wait queue: \(finalStats.waitQueueDepth)")
        
        #expect(metrics.totalAcquisitions == totalOps)
        #expect(metrics.timeouts == 0)
        #expect(finalStats.leased == 0)
        #expect(finalStats.waitQueueDepth == 0)
    }

    @Test("Throughput benchmark across pool sizes")
    func benchmarkThroughputAcrossPoolSizes() async throws {
        struct BenchmarkResult {
            let capacity: Int
            let concurrentTasks: Int
            let operationsPerTask: Int
            let totalDuration: Duration
            let avgWaitTime: Duration?
            let timeouts: Int
            
            var totalOps: Int { concurrentTasks * operationsPerTask }
            var opsPerSecond: Double {
                let seconds = Double(totalDuration.components.seconds) +
                             Double(totalDuration.components.attoseconds) / 1_000_000_000_000_000_000
                return Double(totalOps) / seconds
            }
        }
        
        var results: [BenchmarkResult] = []
        
        let configs: [(Int, Int, Int)] = [
            (2, 10, 20),
            (5, 30, 10),
            (10, 50, 10),
            (20, 100, 5),
        ]
        
        for (capacity, tasks, opsPerTask) in configs {
            let pool = try await ResourcePool<MockResource>(
                capacity: capacity,
                resourceConfig: .init(
                    creationDelay: .milliseconds(1),
                    resetDelay: .milliseconds(1)
                ),
                warmup: true
            )
            
            let start = ContinuousClock.now
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<tasks {
                    group.addTask {
                        for _ in 0..<opsPerTask {
                            try await pool.withResource(timeout: .seconds(10)) { _ in
                                try await Task.sleep(for: .milliseconds(5))
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
            
            let duration = ContinuousClock.now - start
            let metrics = await pool.metrics
            
            results.append(BenchmarkResult(
                capacity: capacity,
                concurrentTasks: tasks,
                operationsPerTask: opsPerTask,
                totalDuration: duration,
                avgWaitTime: metrics.averageWaitTime,
                timeouts: metrics.timeouts
            ))
        }
        
        print("\n=== THROUGHPUT BENCHMARK ===")
        print("Capacity  Tasks  TotalOps  Duration      Ops/Sec   AvgWait    Timeouts")
        print("------------------------------------------------------------------------")
        
        for result in results {
            let waitMs = result.avgWaitTime.map { duration in
                Double(duration.components.attoseconds) / 1_000_000_000_000_000
            } ?? 0.0
            
            print(String(format: "%4lld      %4lld   %5lld     %-12@  %7.1f   %6.1fms  %3lld",
                        result.capacity,
                        result.concurrentTasks,
                        result.totalOps,
                        result.totalDuration.formatted(),
                        result.opsPerSecond,
                        waitMs,
                        result.timeouts))
        }
        
        for result in results {
            #expect(result.timeouts == 0)
        }
    }

    @Test("Latency distribution under contention")
    func benchmarkLatencyDistribution() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        actor LatencyTracker {
            var latencies: [Duration] = []
            
            func record(_ latency: Duration) {
                latencies.append(latency)
            }
            
            func percentile(_ p: Double) -> Duration? {
                guard !latencies.isEmpty else { return nil }
                let sorted = latencies.sorted()
                let index = Int(Double(sorted.count) * p)
                return sorted[Swift.min(index, sorted.count - 1)]
            }
            
            func max() -> Duration? { latencies.max() }
            func min() -> Duration? { latencies.min() }
            
            func avg() -> Duration? {
                guard !latencies.isEmpty else { return nil }
                let total = latencies.reduce(Duration.zero) { $0 + $1 }
                return total / latencies.count
            }
        }
        let tracker = LatencyTracker()
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    for _ in 0..<4 {
                        let start = ContinuousClock.now
                        try await pool.withResource(timeout: .seconds(5)) { _ in
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        let latency = ContinuousClock.now - start
                        await tracker.record(latency)
                    }
                }
            }
            try await group.waitForAll()
        }
        
        print("\n=== LATENCY DISTRIBUTION ===")
        print("Min:  \(await tracker.min()?.formatted() ?? "N/A")")
        print("P50:  \(await tracker.percentile(0.50)?.formatted() ?? "N/A")")
        print("P90:  \(await tracker.percentile(0.90)?.formatted() ?? "N/A")")
        print("P95:  \(await tracker.percentile(0.95)?.formatted() ?? "N/A")")
        print("P99:  \(await tracker.percentile(0.99)?.formatted() ?? "N/A")")
        print("Max:  \(await tracker.max()?.formatted() ?? "N/A")")
        print("Avg:  \(await tracker.avg()?.formatted() ?? "N/A")")
        
        if let p99 = await tracker.percentile(0.99),
           let avg = await tracker.avg() {
            let p99Ns = Double(p99.components.attoseconds) / 1_000_000_000
            let avgNs = Double(avg.components.attoseconds) / 1_000_000_000
            
            let ratio = p99Ns / avgNs
            print("P99/Avg ratio: \(String(format: "%.1fx", ratio))")
            #expect(ratio < 10.0)
        }
    }

    @Test("Scalability - increasing concurrency")
    func benchmarkScalability() async throws {
        struct ScalabilityResult {
            let concurrentWaiters: Int
            let duration: Duration
            let avgWaitTime: Duration?
            let maxQueueDepth: Int
            let handoffRate: Double
            
            var opsPerSecond: Double {
                let seconds = Double(duration.components.seconds) +
                             Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
                return Double(concurrentWaiters) / seconds
            }
        }
        
        var results: [ScalabilityResult] = []
        
        for waiterCount in [10, 30, 50, 100, 200] {
            let pool = try await ResourcePool<MockResource>(
                capacity: 10,
                resourceConfig: .init(
                    creationDelay: .milliseconds(1),
                    resetDelay: .milliseconds(1)
                ),
                warmup: true
            )
            
            actor QueueDepthTracker {
                var maxDepth: Int = 0
                
                func update(_ depth: Int) {
                    maxDepth = max(maxDepth, depth)
                }
            }
            let depthTracker = QueueDepthTracker()
            
            let start = ContinuousClock.now
            
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<waiterCount {
                    group.addTask {
                        do {
                            try await pool.withResource(timeout: .seconds(30)) { _ in
                                try await Task.sleep(for: .milliseconds(20))
                            }
                        } catch {
                            // Ignore
                        }
                    }
                }
                
                group.addTask {
                    for _ in 0..<100 {
                        let stats = await pool.statistics
                        await depthTracker.update(stats.waitQueueDepth)
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                
                await group.waitForAll()
            }
            
            let duration = ContinuousClock.now - start
            let metrics = await pool.metrics
            let maxDepth = await depthTracker.maxDepth
            
            results.append(ScalabilityResult(
                concurrentWaiters: waiterCount,
                duration: duration,
                avgWaitTime: metrics.averageWaitTime,
                maxQueueDepth: maxDepth,
                handoffRate: metrics.handoffRate
            ))
        }
        
        print("\n=== SCALABILITY BENCHMARK ===")
        print("Waiters  Duration     Ops/Sec  AvgWait    MaxQueue  HandoffRate")
        print("------------------------------------------------------------------")
        
        for result in results {
            let waitMs = result.avgWaitTime.map { duration in
                Double(duration.components.attoseconds) / 1_000_000_000_000_000
            } ?? 0.0
            
            print(String(format: "%4lld     %-11@  %6.1f   %6.1fms  %4lld      %4.1f%%",
                        result.concurrentWaiters,
                        result.duration.formatted(),
                        result.opsPerSecond,
                        waitMs,
                        result.maxQueueDepth,
                        result.handoffRate * 100))
        }
        
        if results.count >= 4 {
            let baseline = results[1].opsPerSecond  // 30 waiters
            let scaled = results[3].opsPerSecond    // 100 waiters

            // Calculate scaling efficiency (should be positive = improvement)
            let scalingFactor = scaled / baseline
            let improvement = ((scaled - baseline) / baseline) * 100

            print("\nScalability (30 -> 100 waiters):")
            print("  Baseline (30): \(String(format: "%.1f", baseline)) ops/sec")
            print("  Scaled (100): \(String(format: "%.1f", scaled)) ops/sec")
            print("  Scaling factor: \(String(format: "%.2fx", scalingFactor))")
            print("  Improvement: \(String(format: "%.1f%%", improvement))")

            // Expect near-linear scaling (3.3x more waiters should give ~3x throughput)
            #expect(scalingFactor > 2.5, "Should scale efficiently with more waiters")
        }
    }

    @Test("Direct handoff efficiency benchmark")
    func benchmarkDirectHandoffEfficiency() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try await pool.withResource(timeout: .seconds(5)) { _ in
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            try await group.waitForAll()
        }
        
        let metrics = await pool.metrics
        
        print("\n=== DIRECT HANDOFF EFFICIENCY ===")
        print("Total returns: \(metrics.successfulReturns)")
        print("Direct handoffs: \(metrics.directHandoffs)")
        print("Returns to pool: \(metrics.successfulReturns - metrics.directHandoffs)")
        print("Handoff rate: \(String(format: "%.1f%%", metrics.handoffRate * 100))")
        
        #expect(metrics.handoffRate > 0.5)
    }

    @Test("Pool size impact on performance")
    func benchmarkPoolSizeImpact() async throws {
        struct PerformanceResult {
            let capacity: Int
            let throughput: Double
            let avgWaitTime: Duration
        }
        
        var results: [PerformanceResult] = []
        
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
            
            results.append(PerformanceResult(
                capacity: capacity,
                throughput: throughput,
                avgWaitTime: metrics.averageWaitTime ?? .zero
            ))
        }
        
        print("\n=== POOL SIZE IMPACT ===")
        print("Capacity      Throughput      Avg Wait")
        print("----------------------------------------")
        
        for result in results {
            let waitMs = Double(result.avgWaitTime.components.attoseconds) / 1_000_000_000_000_000
            print(String(format: "%4lld          %6.1f ops/s   %6.1f ms",
                        result.capacity,
                        result.throughput,
                        waitMs))
        }
        
        #expect(results[1].throughput > results[0].throughput)
        #expect(results[2].throughput > results[1].throughput)
    }

    @Test("Memory efficiency - many short-lived acquisitions")
    func benchmarkMemoryEfficiency() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 10,
            resourceConfig: .init(),
            warmup: true
        )
        
        let iterations = 1000
        
        for _ in 0..<iterations {
            _ = try await pool.withResource { $0.id }
        }
        
        let metrics = await pool.metrics
        #expect(metrics.totalAcquisitions == iterations)
        #expect(metrics.timeouts == 0)
        
        let stats = await pool.statistics
        #expect(stats.leased == 0)
        #expect(stats.waitQueueDepth == 0)
    }

    @Test("Burst load handling")
    func benchmarkBurstLoad() async throws {
        let pool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        actor BurstMetrics {
            var burstDurations: [Duration] = []
            
            func recordBurst(_ duration: Duration) {
                burstDurations.append(duration)
            }
        }
        let burstMetrics = BurstMetrics()
        
        // Simulate 5 bursts
        for _ in 0..<5 {
            let burstStart = ContinuousClock.now
            
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
            
            let burstDuration = ContinuousClock.now - burstStart
            await burstMetrics.recordBurst(burstDuration)
            
            // Quiet period
            try await Task.sleep(for: .milliseconds(50))
        }
        
        let bursts = await burstMetrics.burstDurations
        print("\n=== BURST LOAD HANDLING ===")
        for (i, duration) in bursts.enumerated() {
            print("Burst \(i + 1): \(duration.formatted())")
        }
        
        let metrics = await pool.metrics
        #expect(metrics.timeouts == 0)
    }

    @Test("Sustained vs bursty load comparison")
    func benchmarkSustainedVsBursty() async throws {
        // Sustained load - tasks start with small gaps
        let sustainedPool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        let sustainedStart = ContinuousClock.now
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try await sustainedPool.withResource(timeout: .seconds(5)) { _ in
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                try await Task.sleep(for: .milliseconds(5))  // Gap reduces contention
            }
            try await group.waitForAll()
        }
        
        let sustainedDuration = ContinuousClock.now - sustainedStart
        let sustainedMetrics = await sustainedPool.metrics
        
        // Bursty load - concentrated bursts of concurrent tasks
        let burstyPool = try await ResourcePool<MockResource>(
            capacity: 5,
            resourceConfig: .init(),
            warmup: true
        )
        
        let burstyStart = ContinuousClock.now
        
        for _ in 0..<5 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<20 {  // 20 concurrent tasks compete for 5 resources
                    group.addTask {
                        try await burstyPool.withResource(timeout: .seconds(5)) { _ in
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                }
                try await group.waitForAll()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        
        let burstyDuration = ContinuousClock.now - burstyStart
        let burstyMetrics = await burstyPool.metrics
        
        print("\n=== SUSTAINED vs BURSTY LOAD ===")
        print("Sustained (100 tasks with 5ms gaps):")
        print("  Duration: \(sustainedDuration.formatted())")
        print("  Handoff rate: \(String(format: "%.1f%%", sustainedMetrics.handoffRate * 100))")
        print("Bursty (5 bursts of 20 concurrent tasks):")
        print("  Duration: \(burstyDuration.formatted())")
        print("  Handoff rate: \(String(format: "%.1f%%", burstyMetrics.handoffRate * 100))")
        
        // Bursty load creates concentrated contention → more direct handoffs
        // Sustained load with gaps → resources return to pool between tasks
        #expect(burstyMetrics.handoffRate > sustainedMetrics.handoffRate,
                "Bursty load creates concentrated contention → higher handoff rate")
        
        // Both should complete without timeouts
        #expect(sustainedMetrics.timeouts == 0)
        #expect(burstyMetrics.timeouts == 0)
    }
}
