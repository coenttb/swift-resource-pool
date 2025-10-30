import Foundation
import Testing

@testable import ResourcePool

@Suite("ResourcePool - Concurrency & Fairness")
struct ResourcePoolConcurrencyTests {

  @Test("Concurrent access")
  func testConcurrentAccess() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 5,
      resourceConfig: .init(),
      warmup: true
    )

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

    let finalStats = await pool.statistics
    #expect(finalStats.available == 5)
    #expect(finalStats.leased == 0)

    let metrics = await pool.metrics
    #expect(metrics.totalAcquisitions == 20)
    #expect(metrics.successfulReturns == 20)
  }

  @Test("Resource becomes available to waiter")
  func testResourceBecomesAvailableToWaiter() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 1,
      resourceConfig: .init(),
      warmup: true
    )

    actor WaiterState {
      var succeeded = false
      var resourceId: UUID?

      func markSuccess(id: UUID) {
        succeeded = true
        resourceId = id
      }
    }
    let waiterState = WaiterState()

    try await withThrowingTaskGroup(of: Void.self) { group in
      // Task 1: Hold resource briefly
      group.addTask {
        try await pool.withResource { _ in
          let stats = await pool.statistics
          #expect(stats.available == 0)
          #expect(stats.leased == 1)

          try await Task.sleep(for: .milliseconds(100))
        }
      }

      try await Task.sleep(for: .milliseconds(50))

      // Task 2: Wait for resource
      group.addTask {
        let id = try await pool.withResource(timeout: .seconds(5)) { resource in
          resource.id
        }
        await waiterState.markSuccess(id: id)
      }

      try await group.waitForAll()
    }

    let succeeded = await waiterState.succeeded
    #expect(succeeded == true)

    let finalStats = await pool.statistics
    #expect(finalStats.available == 1)
    #expect(finalStats.leased == 0)
  }

  @Test("FIFO fairness - waiters served in order")
  func testFIFOFairness() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 1,
      resourceConfig: .init(),
      warmup: true
    )

    actor AcquisitionTracker {
      var order: [Int] = []

      func recordAcquisition(_ taskId: Int) {
        order.append(taskId)
      }
    }
    let tracker = AcquisitionTracker()

    try await withThrowingTaskGroup(of: Void.self) { group in
      // Task 0: Hold the resource
      group.addTask {
        try await pool.withResource { _ in
          try await Task.sleep(for: .milliseconds(200))
        }
      }

      try await Task.sleep(for: .milliseconds(50))

      // Tasks 1-5: Queue up in order
      for taskId in 1...5 {
        group.addTask {
          try await pool.withResource(timeout: .seconds(5)) { _ in
            await tracker.recordAcquisition(taskId)
            try await Task.sleep(for: .milliseconds(20))
          }
        }
        // Small delay to ensure ordering
        try await Task.sleep(for: .milliseconds(10))
      }

      try await group.waitForAll()
    }

    let order = await tracker.order
    #expect(order == [1, 2, 3, 4, 5])

    let metrics = await pool.metrics
    #expect(metrics.waitersQueued == 5)
  }

  @Test("LIFO resource selection for cache locality")
  func testLIFOResourceSelection() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 3,
      resourceConfig: .init(),
      warmup: true
    )

    actor ResourceUsage {
      var usageOrder: [UUID] = []

      func record(_ id: UUID) {
        usageOrder.append(id)
      }
    }
    let usage = ResourceUsage()

    // Use resources sequentially with pauses
    for _ in 0..<5 {
      let id = try await pool.withResource { resource in
        await resource.use()
        return resource.id
      }
      await usage.record(id)
      try await Task.sleep(for: .milliseconds(50))
    }

    let usageOrder = await usage.usageOrder
    let uniqueResources = Set(usageOrder)

    // With LIFO and sufficient delay, should see resource reuse
    #expect(uniqueResources.count < usageOrder.count)
  }

  @Test("No thundering herd - direct handoff")
  func testNoThunderingHerd() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 2,
      resourceConfig: .init(
        creationDelay: .milliseconds(1),
        resetDelay: .milliseconds(1)
      ),
      warmup: true
    )

    // Wait for background warmup to complete
    try await pool.waitForWarmupCompletion()

    actor AcquisitionTracker {
      var completedTasks: Set<Int> = []

      func recordCompletion(taskId: Int) {
        completedTasks.insert(taskId)
      }

      var count: Int { completedTasks.count }
    }
    let tracker = AcquisitionTracker()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for taskId in 1...20 {
        group.addTask {
          try await pool.withResource(timeout: .seconds(10)) { _ in
            await tracker.recordCompletion(taskId: taskId)
            try await Task.sleep(for: .milliseconds(5))
          }
        }
      }

      try await group.waitForAll()
    }

    let completedCount = await tracker.count
    let metrics = await pool.metrics

    print("\n=== No Thundering Herd Verification ===")
    print("Tasks completed: \(completedCount)/20")
    print("Direct handoffs: \(metrics.directHandoffs)")
    print("Handoff rate: \(String(format: "%.1f%%", metrics.handoffRate * 100))")
    print("Timeouts: \(metrics.timeouts)")

    // Key validations for no thundering herd:

    // 1. All tasks completed successfully (no deadlocks or excessive timeouts)
    #expect(completedCount == 20, "All 20 tasks should complete")

    // 2. High direct handoff rate indicates resources go directly to waiters
    //    With 20 tasks and 2 resources, expect ~18 handoffs (first 2 get from pool)
    #expect(
      metrics.directHandoffs >= 15,
      "Most resources should be handed off directly to waiting tasks"
    )

    // 3. No timeouts from thundering herd contention
    #expect(metrics.timeouts == 0, "No timeouts should occur with efficient queue")

    // 4. Verify queue was actually used (waiters were queued)
    #expect(metrics.waitersQueued >= 10, "Many tasks should have waited in queue")
  }

  @Test("High concurrency scales well")
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
              try await Task.sleep(for: .microseconds(100))
              _ = resource.id
            }
          }
        }
      }

      try await group.waitForAll()
    }

    let finalStats = await pool.statistics
    #expect(finalStats.leased == 0)
    #expect(finalStats.available <= 10)

    let metrics = await pool.metrics
    #expect(metrics.totalAcquisitions == taskCount * operationsPerTask)
    #expect(metrics.timeouts == 0)
  }

  @Test("Automatic cleanup on cancellation")
  func testAutomaticCleanupOnCancellation() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 2,
      resourceConfig: .init(),
      warmup: true
    )

    actor ResourceTracker {
      var acquiredIds: Set<UUID> = []

      func track(_ id: UUID) {
        acquiredIds.insert(id)
      }

      var count: Int { acquiredIds.count }
    }
    let tracker = ResourceTracker()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<5 {
        group.addTask {
          do {
            try await pool.withResource(timeout: .seconds(1)) { resource in
              await tracker.track(resource.id)
              try await Task.sleep(for: .seconds(10))
            }
          } catch {
            // Cancellation or timeout expected
          }
        }
      }

      try? await Task.sleep(for: .milliseconds(100))

      group.cancelAll()

      await group.waitForAll()
    }

    let acquiredCount = await tracker.count
    #expect(acquiredCount > 0)

    let finalStats = await pool.statistics
    #expect(finalStats.leased == 0)
    #expect(finalStats.available == 2)
  }

  @Test("Statistics remain consistent under concurrent access")
  func testStatisticsConsistency() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 5,
      resourceConfig: .init(),
      warmup: true
    )

    // Wait for background warmup to complete
    try await pool.waitForWarmupCompletion()

    actor StatsValidator {
      var inconsistencies: [String] = []

      func validate(_ stats: Statistics) {
        // totalCreated should never exceed capacity
        if stats.totalCreated > stats.capacity {
          inconsistencies.append(
            "totalCreated (\(stats.totalCreated)) > capacity (\(stats.capacity))"
          )
        }
        // available + leased should be ≤ totalCreated (can be < during lazy creation)
        let accountedFor = stats.available + stats.leased
        if accountedFor > stats.totalCreated {
          inconsistencies.append(
            "available+leased (\(accountedFor)) > totalCreated (\(stats.totalCreated))"
          )
        }
        if stats.available < 0 || stats.leased < 0 {
          inconsistencies.append(
            "Negative values: available=\(stats.available), leased=\(stats.leased)"
          )
        }
      }

      var isValid: Bool { inconsistencies.isEmpty }
    }
    let validator = StatsValidator()

    await withTaskGroup(of: Void.self) { group in
      // Hammer the pool
      for _ in 0..<20 {
        group.addTask {
          do {
            try await pool.withResource(timeout: .seconds(1)) { _ in
              try await Task.sleep(for: .milliseconds(10))
            }
          } catch {
            // Timeouts expected
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

  @Test("Multiple waiters wake up in order")
  func testMultipleWaitersOrdering() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 1,
      resourceConfig: .init(),
      warmup: true
    )

    actor OrderTracker {
      var acquisitionOrder: [Int] = []
      var queuedOrder: [Int] = []

      func recordQueued(_ id: Int) {
        queuedOrder.append(id)
      }

      func recordAcquired(_ id: Int) {
        acquisitionOrder.append(id)
      }
    }
    let tracker = OrderTracker()

    try await withThrowingTaskGroup(of: Void.self) { group in
      // Hold the resource
      group.addTask {
        try await pool.withResource { _ in
          try await Task.sleep(for: .milliseconds(300))
        }
      }

      try await Task.sleep(for: .milliseconds(50))

      // Queue up 10 waiters
      for i in 1...10 {
        await tracker.recordQueued(i)
        group.addTask {
          try await pool.withResource(timeout: .seconds(10)) { _ in
            await tracker.recordAcquired(i)
            try await Task.sleep(for: .milliseconds(20))
          }
        }
        try await Task.sleep(for: .milliseconds(5))
      }

      try await group.waitForAll()
    }

    let queuedOrder = await tracker.queuedOrder
    let acquisitionOrder = await tracker.acquisitionOrder

    #expect(queuedOrder == acquisitionOrder)
    #expect(acquisitionOrder == Array(1...10))
  }

  @Test("Direct handoff under sustained load")
  func testDirectHandoffEfficiency() async throws {
    let pool = try await ResourcePool<MockResource>(
      capacity: 3,
      resourceConfig: .init(),
      warmup: true
    )

    // Create sustained load
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          try await pool.withResource(timeout: .seconds(5)) { _ in
            try await Task.sleep(for: .milliseconds(10))
          }
        }
      }
      try await group.waitForAll()
    }

    let metrics = await pool.metrics

    // Under sustained load, most resources should be handed off directly
    #expect(metrics.directHandoffs > 20)
    #expect(metrics.handoffRate > 0.4)

    print("\nDirect Handoff Efficiency:")
    print("Total returns: \(metrics.successfulReturns)")
    print("Direct handoffs: \(metrics.directHandoffs)")
    print("Handoff rate: \(String(format: "%.1f%%", metrics.handoffRate * 100))")
  }
}
