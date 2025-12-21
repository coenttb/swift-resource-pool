// Foundation-free resource pooling library

// MARK: - Pool Errors

public enum PoolError: Error, Sendable, Equatable {
  case timeout
  case closed
  case creationFailed(String)
  case resetFailed(String)
  case drainTimeout
}

// MARK: - PoolableResource Protocol

/// Protocol for resources that can be managed by a ResourcePool
///
/// Resources must be reference types (classes or actors) because the pool
/// tracks them using ObjectIdentifier.
///
/// # Thread Safety Requirements
/// All methods must be safe to call concurrently and from any isolation context.
///
/// # Cancellation Safety
/// **IMPORTANT**: The `reset()` method MUST be cancellation-safe, meaning it should
/// leave the resource in a valid, reusable state even if cancelled mid-operation.
/// If your reset logic cannot be made cancellation-safe, consider making it non-async
/// or using a synchronization mechanism to ensure atomicity.
public protocol PoolableResource: Sendable, AnyObject {
  associatedtype Config: Sendable

  /// Create a new resource instance
  static func create(config: Config) async throws -> Self

  /// Check if the resource is still valid and can be reused
  /// This is called before returning a resource from the pool.
  func validate() async -> Bool

  /// Reset the resource to a clean state for reuse
  ///
  /// **Cancellation Safety**: This method MUST leave the resource in a valid state
  /// even if cancelled. The pool will return the resource even on cancellation.
  func reset() async throws
}

// MARK: - Resource Factory

private struct ResourceFactory<Resource: PoolableResource>: Sendable {
  let config: Resource.Config

  func create() async throws -> Resource {
    try await Resource.create(config: config)
  }
}

// MARK: - Waiter

/// Represents a task waiting for a resource
private struct Waiter<Resource: PoolableResource>: Sendable {
  let id: UInt64
  let continuation: CheckedContinuation<Resource, Error>
  let deadline: ContinuousClock.Instant

  var isExpired: Bool {
    ContinuousClock.now >= deadline
  }
}

// MARK: - Resource Metadata

/// Tracks usage statistics for resource cycling
private struct ResourceMetadata: Sendable {
  var usageCount: Int

  init() {
    self.usageCount = 0
  }

  mutating func incrementUsage() {
    usageCount += 1
  }
}

// MARK: - Resource Pool

/// A thread-safe, actor-based resource pool with fair FIFO waiter queue
///
/// This implementation eliminates the thundering herd problem by using a FIFO
/// queue of continuations. When a resource becomes available, only the first
/// waiter in the queue is resumed - not all waiters.
///
/// # Features
/// - Lazy resource creation up to configured capacity
/// - Optional background warmup to pre-create resources (non-blocking)
/// - Automatic validation and reset on return
/// - Timeout support for acquisition
/// - Fair FIFO ordering prevents starvation
/// - Cancellation-safe resource usage via `withResource()`
/// - No thundering herd - O(1) waiter wakeup
/// - Production metrics tracking
///
/// # Important Notes
/// - Resources MUST be reference types (classes/actors)
/// - Always use `withResource()` for resource access
/// - Resources are validated and reset after each use
/// - Failed resources are discarded and lazily recreated
/// - Scales efficiently to 200+ concurrent waiters
///
/// # Basic Usage
/// ```swift
/// let pool = try await ResourcePool<MyResource>(
///     capacity: 10,
///     resourceConfig: .default,
///     warmup: true
/// )
///
/// let result = try await pool.withResource(timeout: .seconds(10)) { resource in
///     try await resource.performWork()
/// }
/// // Resource automatically returned, even if cancelled
/// ```
///
/// # Sharing Pools Across Your Application
///
/// **IMPORTANT:** For system-limited resources (WebViews, database connections, file handles),
/// creating multiple pool instances can lead to resource exhaustion. Instead, use a single
/// shared pool via a global actor:
///
/// ```swift
/// // Define a global actor to hold your shared pool
/// @globalActor
/// public actor MyResourcePoolActor {
///     public static let shared = MyResourcePoolActor()
///
///     private var sharedPool: ResourcePool<MyResource>?
///
///     public func getPool() async throws -> ResourcePool<MyResource> {
///         if let existing = sharedPool {
///             return existing
///         }
///
///         let pool = try await ResourcePool<MyResource>(
///             capacity: 10,
///             resourceConfig: .default,
///             warmup: true
///         )
///         sharedPool = pool
///         return pool
///     }
/// }
///
/// // Usage: All callers share the same pool
/// let pool = try await MyResourcePoolActor.shared.getPool()
/// try await pool.withResource { resource in
///     // Work with resource
/// }
/// ```
///
/// **Why share pools?**
/// - Prevents resource exhaustion (e.g., 7 parallel operations × 8 WebViews each = 56 WebViews)
/// - One warmup cost amortized across all users
/// - Better resource utilization through shared queuing
/// - System limits respected (macOS limits concurrent WebKit processes, DB connections, etc.)
///
/// **When NOT to share:**
/// - Different resource configurations needed
/// - Isolated testing scenarios
/// - Short-lived, bounded workloads
/// - Resources with incompatible lifecycles
public actor ResourcePool<Resource: PoolableResource> {
  // MARK: - State

  /// Available resources waiting to be acquired (LIFO for cache locality)
  private var available: [Resource] = []

  /// ObjectIdentifiers of resources currently leased
  private var leased: Set<ObjectIdentifier> = []

  /// FIFO queue of tasks waiting for resources (eliminates thundering herd)
  private var waitQueue: [Waiter<Resource>] = []

  /// Maximum resources to create
  private let capacity: Int

  /// Factory for creating resources
  private let factory: ResourceFactory<Resource>

  /// Total resources created (to enforce capacity)
  private var totalCreated: Int = 0

  /// Whether pool is closed
  private var isClosed = false

  /// Whether pool is draining (rejecting new acquisitions but accepting returns)
  private var isDraining = false

  /// Metrics for observability
  private var _metrics = Metrics()

  /// Task to periodically clean expired waiters
  private var cleanupTask: Task<Void, Never>?

  /// Resource usage tracking for cycling
  private var resourceMetadata: [ObjectIdentifier: ResourceMetadata] = [:]

  /// Maximum uses before cycling a resource (nil = no cycling)
  private let maxUsesBeforeCycling: Int?

  /// Counter for generating unique waiter IDs
  private var nextWaiterId: UInt64 = 0

  // MARK: - Initialization

  /// Create a new resource pool
  /// - Parameters:
  ///   - capacity: Maximum number of resources to create (must be > 0)
  ///   - resourceConfig: Configuration for creating resources
  ///   - warmup: If true, pre-create resources in background; if false, create lazily on demand
  ///   - maxUsesBeforeCycling: Maximum times a resource can be used before being recycled (nil = no limit)
  public init(
    capacity: Int,
    resourceConfig: Resource.Config,
    warmup: Bool = true,
    maxUsesBeforeCycling: Int? = nil
  ) async throws {
    precondition(capacity > 0, "Capacity must be positive")
    precondition(
      capacity <= Int.max / 2,
      "Capacity must be reasonable (max \(Int.max / 2)) to prevent overflow"
    )

    self.capacity = capacity
    self.factory = ResourceFactory(config: resourceConfig)
    self.maxUsesBeforeCycling = maxUsesBeforeCycling

    // Start background cleanup task for expired waiters
    startCleanupTask()

    // Warmup strategy:
    // - Create first resource synchronously for immediate availability (eliminates cold start)
    // - Create remaining resources in background (non-blocking)
    if warmup {
      do {
        // Create first resource synchronously - critical for cold start performance
        let firstResource = try await factory.create()
        totalCreated += 1
        let id = ObjectIdentifier(firstResource)
        resourceMetadata[id] = ResourceMetadata()
        available.append(firstResource)

        // Continue warmup for remaining resources in background
        if capacity > 1 {
          startBackgroundWarmup()
        }
      } catch {
        _metrics.recordCreationFailure()
        // If first resource fails, fall back to full background warmup
        startBackgroundWarmup()
      }
    }

    verifyAccounting()
  }

  // MARK: - Public API

  /// Use a resource with automatic cleanup, even on cancellation
  ///
  /// This is the recommended way to use pool resources. The resource is
  /// automatically returned to the pool when the operation completes, fails,
  /// or is cancelled.
  ///
  /// **Cancellation Safety:** This method guarantees resource cleanup even when cancelled.
  /// Actor-isolated cleanup methods complete atomically before cancellation propagates.
  ///
  /// **Fairness:** Waiters are served in FIFO order to prevent starvation.
  ///
  /// - Parameters:
  ///   - timeout: Maximum time to wait for a resource
  ///   - operation: Async closure that uses the resource
  /// - Returns: The result of the operation
  /// - Throws: `PoolError.timeout` if timeout expires, `PoolError.closed` if pool is closed,
  ///           or any error thrown by the operation
  ///
  /// # Example
  /// ```swift
  /// let result = try await pool.withResource(timeout: .seconds(5)) { resource in
  ///     try await resource.performWork()
  /// }
  /// ```
  public func withResource<T: Sendable>(
    timeout: Duration = .seconds(30),
    _ operation: (Resource) async throws -> T
  ) async throws -> T {
    precondition(timeout > .zero, "Timeout must be positive")

    let acquisitionStart = ContinuousClock.now

    // Acquire resource (FIFO ordering)
    let resource = try await acquireResource(timeout: timeout)

    let acquisitionDuration = ContinuousClock.now - acquisitionStart
    _metrics.recordAcquisition(waitTime: acquisitionDuration)

    // Use with automatic cleanup on any exit path
    // CRITICAL: Direct await ensures cleanup completes even on cancellation
    do {
      let result = try await operation(resource)
      await release(resource)
      return result
    } catch {
      // Actor-isolated release() completes atomically before cancellation propagates
      await release(resource)
      throw error
    }
  }

  /// Get current pool statistics
  ///
  /// Returns a point-in-time snapshot. Values may change immediately after
  /// being read due to concurrent operations.
  public nonisolated var statistics: Statistics {
    get async {
      await Statistics(
        available: available.count,
        leased: leased.count,
        capacity: capacity,
        waitQueueDepth: waitQueue.count,
        totalCreated: totalCreated
      )
    }
  }

  /// Get current pool metrics
  ///
  /// Provides observability into pool behavior for monitoring and debugging.
  public nonisolated var metrics: Metrics {
    get async {
      var metricsSnapshot = await _metrics
      metricsSnapshot.currentStatistics = await statistics
      return metricsSnapshot
    }
  }

  /// Drain the pool gracefully
  ///
  /// This method:
  /// 1. Stops accepting new acquisitions (sets `isDraining`)
  /// 2. Resumes all waiting tasks with `PoolError.closed`
  /// 3. Waits for all leased resources to be returned (up to timeout)
  ///
  /// After draining, the pool stops accepting new acquisitions but continues to
  /// accept resource returns from in-flight operations. The pool can then be safely
  /// deallocated via ARC, or you can call `close()` to explicitly clear all state.
  ///
  /// Uses exponential backoff for efficient polling (starts at 10ms, doubles to max 100ms).
  ///
  /// Use cases:
  /// - Pool replacement: `drain()` then let ARC deallocate
  /// - Graceful shutdown: `drain()` then `close()` to clear state
  ///
  /// - Parameter timeout: Maximum time to wait for resources to be returned
  /// - Throws: `PoolError.drainTimeout` if timeout expires with resources still leased
  public func drain(timeout: Duration = .seconds(30)) async throws {
    isDraining = true

    // Resume all waiters with closed error
    resumeAllWaitersWithError(PoolError.closed)

    // Wait for leased resources to return with exponential backoff
    let deadline = ContinuousClock.now + timeout
    var backoff = Duration.milliseconds(10)
    let maxBackoff = Duration.milliseconds(100)

    while !leased.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: backoff)
      // Exponential backoff: double the wait time up to max
      backoff = min(backoff * 2, maxBackoff)
    }

    if !leased.isEmpty {
      throw PoolError.drainTimeout
    }

    // Note: We don't call close() here.
    // Pool is draining (isDraining = true) so no new acquisitions,
    // but resources can still be returned.
    // Caller can call close() explicitly if needed, or just let ARC deallocate.
  }

  /// Close the pool immediately
  ///
  /// This closes the pool and clears all tracking state. Resources that are
  /// currently leased will NOT be waited for. For graceful shutdown, use
  /// `drain()` instead.
  ///
  /// After closing:
  /// - New acquisitions will fail with `PoolError.closed`
  /// - All waiters are resumed with `PoolError.closed`
  /// - All internal state is cleared
  public func close() async {
    isClosed = true
    cleanupTask?.cancel()
    cleanupTask = nil

    // Resume all waiters with closed error
    resumeAllWaitersWithError(PoolError.closed)

    available.removeAll()
    leased.removeAll()
    totalCreated = 0

    verifyAccounting()
  }

  // MARK: - Internal Implementation

  /// Acquire a resource with fair FIFO semantics and cancellation support
  private func acquireResource(timeout: Duration) async throws -> Resource {
    if isClosed || isDraining {
      throw PoolError.closed
    }

    // FAST PATH: Resource immediately available
    if let resource = available.popLast() {
      let id = ObjectIdentifier(resource)
      leased.insert(id)
      recordResourceAcquisition(id: id)
      return resource
    }

    // LAZY CREATION: Create if under capacity
    if totalCreated < capacity {
      // Reserve capacity atomically
      totalCreated += 1
      do {
        let resource = try await factory.create()
        let id = ObjectIdentifier(resource)
        leased.insert(id)
        resourceMetadata[id] = ResourceMetadata()
        recordResourceAcquisition(id: id)
        return resource
      } catch {
        // Creation failed - release reserved capacity
        totalCreated -= 1
        _metrics.recordCreationFailure()
        throw PoolError.creationFailed("Failed to create resource: \(error)")
      }
    }

    // WAIT PATH: Pool exhausted, add to FIFO queue with cancellation support
    nextWaiterId += 1
    let waiterId = nextWaiterId

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let waiter = Waiter(
          id: waiterId,
          continuation: continuation,
          deadline: ContinuousClock.now + timeout
        )

        waitQueue.append(waiter)
        _metrics.recordWaiterQueued()

        // Schedule timeout check
        Task {
          try? await Task.sleep(for: timeout)
          handleTimeout(waiterId: waiterId)
        }
      }
    } onCancel: {
      Task {
        await handleCancellation(waiterId: waiterId)
      }
    }
  }

  /// Handle cancellation of a waiting task
  private func handleCancellation(waiterId: UInt64) {
    guard let index = waitQueue.firstIndex(where: { $0.id == waiterId }) else {
      return  // Already resumed (got resource, timed out, or pool closed)
    }

    let waiter = waitQueue.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  /// Handle timeout for a specific waiter
  private func handleTimeout(waiterId: UInt64) {
    guard let index = waitQueue.firstIndex(where: { $0.id == waiterId }) else {
      return  // Already resumed (got resource or pool closed)
    }

    let waiter = waitQueue.remove(at: index)
    _metrics.recordTimeout()
    waiter.continuation.resume(throwing: PoolError.timeout)
  }

  /// Release a resource back to the pool
  private func release(_ resource: Resource) async {
    let id = ObjectIdentifier(resource)

    // Double-release protection
    guard leased.remove(id) != nil else {
      return
    }

    // If pool is fully closed (not just draining), don't process the return - just discard
    // When draining, we still accept returns from in-flight operations
    guard !isClosed else {
      totalCreated -= 1
      return
    }

    // Check if resource should be cycled
    if let maxUses = maxUsesBeforeCycling,
      let metadata = resourceMetadata[id],
      metadata.usageCount >= maxUses
    {
      // Resource exceeded max uses - discard and replace
      totalCreated -= 1
      resourceMetadata.removeValue(forKey: id)
      _metrics.recordResourceCycled()
      await tryServeNextWaiter()
      return
    }

    // Validate resource
    let isValid = await resource.validate()
    guard isValid else {
      // Resource is invalid - discard it
      totalCreated -= 1
      resourceMetadata.removeValue(forKey: id)
      _metrics.recordValidationFailure()
      // Try to serve next waiter with a new resource
      await tryServeNextWaiter()
      return
    }

    // Reset resource - handle cancellation during cleanup
    do {
      try await resource.reset()

      // Check again if pool was closed during reset
      guard !isClosed else {
        totalCreated -= 1
        return
      }

      _metrics.recordSuccessfulReturn()

      // KEY: Hand off resource directly to next waiter or return to pool
      handOffOrReturnResource(resource)

    } catch is CancellationError {
      // Cancellation during reset - re-validate for safety
      // Even though the protocol requires cancellation-safe reset(),
      // we validate defensively to protect against buggy implementations
      let isValid = await resource.validate()
      guard isValid else {
        // Resource left in bad state - discard it
        totalCreated -= 1
        resourceMetadata.removeValue(forKey: id)
        _metrics.recordResetFailure()
        await tryServeNextWaiter()
        return
      }

      guard !isClosed else {
        totalCreated -= 1
        return
      }

      _metrics.recordSuccessfulReturn()
      handOffOrReturnResource(resource)

    } catch {
      // Actual reset failure - discard resource
      totalCreated -= 1
      resourceMetadata.removeValue(forKey: id)
      _metrics.recordResetFailure()
      // Try to serve next waiter with a new resource
      await tryServeNextWaiter()
    }
  }

  /// Hand off resource to next waiter or return to available pool
  ///
  /// This is the core of the thundering herd fix! Instead of broadcasting
  /// to ALL waiters, we directly resume EXACTLY ONE continuation.
  private func handOffOrReturnResource(_ resource: Resource) {
    // Remove expired waiters with batching limit to prevent CPU spikes
    // Under high contention with many timeouts, limit removals per call
    let maxRemovalsPerCall = 10
    var removedCount = 0
    var expiredWaiters: [Waiter<Resource>] = []

    waitQueue.removeAll { waiter in
      guard removedCount < maxRemovalsPerCall else { return false }
      if waiter.isExpired {
        expiredWaiters.append(waiter)
        removedCount += 1
        return true
      }
      return false
    }

    // Resume expired waiters with timeout error
    for waiter in expiredWaiters {
      _metrics.recordTimeout()
      waiter.continuation.resume(throwing: PoolError.timeout)
    }

    // If there's a waiter, hand off directly (FIFO for fairness)
    if let waiter = waitQueue.first {
      waitQueue.removeFirst()
      let id = ObjectIdentifier(resource)
      leased.insert(id)
      _metrics.recordDirectHandoff()
      recordResourceAcquisition(id: id)

      // Resume the continuation with the resource
      // This wakes EXACTLY ONE task - no thundering herd!
      waiter.continuation.resume(returning: resource)
    } else {
      // No waiters - return to pool (LIFO for cache locality)
      available.append(resource)
    }
  }

  /// Try to serve the next waiter by creating a new resource
  private func tryServeNextWaiter() async {
    guard !waitQueue.isEmpty, totalCreated < capacity else {
      return
    }

    // Reserve capacity before async creation
    totalCreated += 1

    do {
      let resource = try await factory.create()
      let id = ObjectIdentifier(resource)

      // Initialize metadata for new resource
      resourceMetadata[id] = ResourceMetadata()

      // Hand off to next waiter
      if let waiter = waitQueue.first {
        waitQueue.removeFirst()
        leased.insert(id)
        recordResourceAcquisition(id: id)
        _metrics.recordDirectHandoff()
        waiter.continuation.resume(returning: resource)
      } else {
        // No waiter anymore, add to available pool
        available.append(resource)
      }
    } catch {
      // Creation failed, release reserved capacity
      totalCreated -= 1
      _metrics.recordCreationFailure()
    }
  }

  /// Resume all waiters with an error (used during close/drain)
  private func resumeAllWaitersWithError(_ error: Error) {
    for waiter in waitQueue {
      waiter.continuation.resume(throwing: error)
    }
    waitQueue.removeAll()
  }

  /// Background task to clean up expired waiters
  private func startCleanupTask() {
    cleanupTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        await self?.cleanExpiredWaiters()
      }
    }
  }

  /// Start background warmup to pre-create resources without blocking initialization
  ///
  /// This creates resources in the background until capacity is reached.
  /// The function automatically accounts for already-created resources by
  /// checking totalCreated.
  private func startBackgroundWarmup() {
    Task { [weak self] in
      guard let self = self else { return }

      // Pre-create remaining resources up to capacity
      // shouldCreateWarmupResource() checks totalCreated, so this naturally
      // accounts for any resources already created
      while await self.shouldCreateWarmupResource() {
        do {
          let resource = try await self.factory.create()

          // Add to pool - this increments totalCreated
          await self.addWarmupResource(resource, incrementCount: true)
        } catch {
          await self.recordCreationFailure()
        }
      }
    }
  }

  /// Check if we should create another warmup resource
  private func shouldCreateWarmupResource() -> Bool {
    return !isClosed && totalCreated < capacity
  }

  /// Add a warmed-up resource to the pool
  private func addWarmupResource(_ resource: Resource, incrementCount: Bool) {
    guard !isClosed else {
      // Pool closed - discard resource
      return
    }

    // Increment count BEFORE checking capacity to prevent race conditions
    if incrementCount {
      totalCreated += 1

      // Check if we exceeded capacity (race condition with concurrent warmup)
      guard totalCreated <= capacity else {
        // Over capacity - rollback and discard
        totalCreated -= 1
        return
      }
    }

    // Initialize metadata for warmup resources
    let id = ObjectIdentifier(resource)
    if resourceMetadata[id] == nil {
      resourceMetadata[id] = ResourceMetadata()
    }

    // Add the resource to the pool
    handOffOrReturnResource(resource)
  }

  /// Record a creation failure in metrics
  private func recordCreationFailure() {
    _metrics.recordCreationFailure()
  }

  /// Remove expired waiters and resume with timeout error
  private func cleanExpiredWaiters() {
    var expiredWaiters: [Waiter<Resource>] = []

    waitQueue.removeAll { waiter in
      if waiter.isExpired {
        expiredWaiters.append(waiter)
        return true
      }
      return false
    }

    for waiter in expiredWaiters {
      _metrics.recordTimeout()
      waiter.continuation.resume(throwing: PoolError.timeout)
    }
  }

  /// Record resource acquisition and increment usage count
  private func recordResourceAcquisition(id: ObjectIdentifier) {
    resourceMetadata[id, default: ResourceMetadata()].incrementUsage()
  }

  // MARK: - Debug Support

  #if DEBUG
    /// Verify accounting invariant: available + leased = totalCreated
    ///
    /// NOTE: This should only be called when the pool is quiescent (no operations in-flight).
    private func verifyAccounting() {
      let actual = available.count + leased.count
      assert(
        actual == totalCreated,
        """
        Accounting mismatch:
          available: \(available.count)
          leased: \(leased.count)
          sum: \(actual)
          totalCreated: \(totalCreated)
        """
      )
    }

    /// Test helper: Verify accounting at a quiescent point
    internal func testVerifyAccounting() {
      verifyAccounting()
    }
  #else
    private func verifyAccounting() {}
  #endif

  /// Test helper: Wait for background warmup to complete
  /// This is useful in tests that check statistics immediately after pool creation
  internal func waitForWarmupCompletion(timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while totalCreated < capacity && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if totalCreated < capacity {
      throw PoolError.timeout
    }
  }

  deinit {
    cleanupTask?.cancel()
  }
}

// MARK: - Statistics

/// Point-in-time statistics about pool state
public struct Statistics: Sendable, Equatable {
  /// Number of resources currently available for acquisition
  public let available: Int

  /// Number of resources currently leased out
  public let leased: Int

  /// Maximum capacity of the pool
  public let capacity: Int

  /// Number of tasks currently waiting for a resource
  public let waitQueueDepth: Int

  /// Total resources created (debug)
  public let totalCreated: Int

  /// Alias for leased count
  public var inUse: Int { leased }

  /// Current utilization as a percentage (0.0 to 1.0)
  public var utilization: Double {
    guard capacity > 0 else { return 0 }
    return Double(leased) / Double(capacity)
  }

  /// Indicates backpressure - tasks are waiting for resources
  public var hasBackpressure: Bool {
    waitQueueDepth > 0
  }
}

// MARK: - Metrics

/// Production metrics for pool observability
public struct Metrics: Sendable {
  /// Current pool state snapshot
  public var currentStatistics: Statistics = Statistics(
    available: 0,
    leased: 0,
    capacity: 0,
    waitQueueDepth: 0,
    totalCreated: 0
  )

  /// Total number of successful resource acquisitions
  public private(set) var totalAcquisitions: Int = 0

  /// Total number of acquisition timeouts
  public private(set) var timeouts: Int = 0

  /// Total number of resources that failed validation
  public private(set) var validationFailures: Int = 0

  /// Total number of resources that failed reset
  public private(set) var resetFailures: Int = 0

  /// Total number of resource creation failures
  public private(set) var creationFailures: Int = 0

  /// Total number of successful resource returns
  public private(set) var successfulReturns: Int = 0

  /// Total number of tasks that entered the wait queue
  public private(set) var waitersQueued: Int = 0

  /// Total number of resources handed directly to waiters (vs returned to pool)
  public private(set) var directHandoffs: Int = 0

  /// Total number of resources cycled due to max usage
  public private(set) var resourcesCycled: Int = 0

  /// Total wait time across all acquisitions
  private var totalWaitTime: Duration = .zero

  /// Average wait time for resource acquisition
  public var averageWaitTime: Duration? {
    guard totalAcquisitions > 0 else { return nil }
    return totalWaitTime / totalAcquisitions
  }

  /// Percentage of resources that were handed directly to waiters
  ///
  /// High handoff rate indicates sustained load with efficient direct handoff.
  /// Low handoff rate indicates bursty load or excess capacity.
  public var handoffRate: Double {
    guard successfulReturns > 0 else { return 0 }
    return Double(directHandoffs) / Double(successfulReturns)
  }

  // MARK: - Internal Recording Methods

  mutating func recordAcquisition(waitTime: Duration) {
    totalAcquisitions += 1
    totalWaitTime += waitTime
  }

  mutating func recordTimeout() {
    timeouts += 1
  }

  mutating func recordValidationFailure() {
    validationFailures += 1
  }

  mutating func recordResetFailure() {
    resetFailures += 1
  }

  mutating func recordCreationFailure() {
    creationFailures += 1
  }

  mutating func recordSuccessfulReturn() {
    successfulReturns += 1
  }

  mutating func recordWaiterQueued() {
    waitersQueued += 1
  }

  mutating func recordDirectHandoff() {
    directHandoffs += 1
  }

  mutating func recordResourceCycled() {
    resourcesCycled += 1
  }
}

// MARK: - Duration Extensions

extension Duration {
  private static func / (lhs: Duration, rhs: Int) -> Duration {
    // Convert to nanoseconds with better precision
    // attoseconds = 10^-18 seconds, so attoseconds / 10^9 = nanoseconds
    let totalNanoseconds =
      (lhs.components.seconds * 1_000_000_000) + (lhs.components.attoseconds / 1_000_000_000)
    let avgNanoseconds = totalNanoseconds / Int64(rhs)
    return .nanoseconds(avgNanoseconds)
  }
}
