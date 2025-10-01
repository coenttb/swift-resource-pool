import Foundation

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
public protocol PoolableResource: Sendable, AnyObject {
    associatedtype Config: Sendable
    
    /// Create a new resource instance
    static func create(config: Config) async throws -> Self
    
    /// Check if the resource is still valid and can be reused
    func validate() async -> Bool
    
    /// Reset the resource to a clean state for reuse
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
    let id: UUID
    let continuation: CheckedContinuation<Resource, Error>
    let deadline: ContinuousClock.Instant
    
    var isExpired: Bool {
        ContinuousClock.now >= deadline
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
/// - Optional warmup to pre-create resources
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
/// # Example
/// ```swift
/// let pool = try await ResourcePool<WKWebView>(
///     capacity: 10,
///     resourceConfig: .init(),
///     warmup: true
/// )
///
/// let pdfData = try await pool.withResource(timeout: .seconds(10)) { webView in
///     try await webView.renderPDF(html: htmlContent)
/// }
/// // Resource automatically returned, even if cancelled
/// ```
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
    
    /// Metrics for observability
    private var _metrics = Metrics()
    
    /// Task to periodically clean expired waiters
    private var cleanupTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    /// Create a new resource pool
    /// - Parameters:
    ///   - capacity: Maximum number of resources to create (must be > 0)
    ///   - resourceConfig: Configuration for creating resources
    ///   - warmup: If true, pre-create all resources; if false, create lazily on demand
    public init(
        capacity: Int,
        resourceConfig: Resource.Config,
        warmup: Bool = true
    ) async throws {
        precondition(capacity > 0, "Capacity must be positive")
        
        self.capacity = capacity
        self.factory = ResourceFactory(config: resourceConfig)
        
        // Pre-create resources if warmup enabled
        if warmup {
            for _ in 0..<capacity {
                do {
                    let resource = try await factory.create()
                    available.append(resource)
                    totalCreated += 1
                } catch {
                    _metrics.recordCreationFailure()
                    throw PoolError.creationFailed("Warmup failed: \(error)")
                }
            }
        }
        
        // Start background cleanup task for expired waiters
        startCleanupTask()
        
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
    public func withResource<T>(
        timeout: Duration = .seconds(30),
        _ operation: (Resource) async throws -> T
    ) async throws -> T {
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
                waitQueueDepth: waitQueue.count
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
    
    /// Drain the pool gracefully and close it
    ///
    /// This method:
    /// 1. Stops accepting new acquisitions (sets `isClosed`)
    /// 2. Resumes all waiting tasks with `PoolError.closed`
    /// 3. Waits for all leased resources to be returned (up to timeout)
    /// 4. Closes the pool and clears all state
    ///
    /// Use this for graceful shutdown to ensure all resources are properly returned.
    ///
    /// - Parameter timeout: Maximum time to wait for resources to be returned
    /// - Throws: `PoolError.drainTimeout` if timeout expires with resources still leased
    public func drain(timeout: Duration = .seconds(30)) async throws {
        isClosed = true
        
        // Resume all waiters with closed error
        resumeAllWaitersWithError(PoolError.closed)
        
        // Wait for leased resources to return
        let deadline = ContinuousClock.now + timeout
        while !leased.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        
        if !leased.isEmpty {
            throw PoolError.drainTimeout
        }
        
        await close()
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
        if isClosed {
            throw PoolError.closed
        }
        
        // FAST PATH: Resource immediately available
        if let resource = available.popLast() {
            leased.insert(ObjectIdentifier(resource))
            return resource
        }
        
        // LAZY CREATION: Create if under capacity
        if totalCreated < capacity {
            do {
                let resource = try await factory.create()
                totalCreated += 1
                leased.insert(ObjectIdentifier(resource))
                return resource
            } catch {
                _metrics.recordCreationFailure()
                throw PoolError.creationFailed("Failed to create resource: \(error)")
            }
        }
        
        // WAIT PATH: Pool exhausted, add to FIFO queue with cancellation support
        let waiterId = UUID()
        
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
                    await handleTimeout(waiterId: waiterId)
                }
            }
        } onCancel: {
            Task {
                await handleCancellation(waiterId: waiterId)
            }
        }
    }

    /// Handle cancellation of a waiting task
    private func handleCancellation(waiterId: UUID) {
        guard let index = waitQueue.firstIndex(where: { $0.id == waiterId }) else {
            return  // Already resumed (got resource, timed out, or pool closed)
        }
        
        let waiter = waitQueue.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
    
    /// Handle timeout for a specific waiter
    private func handleTimeout(waiterId: UUID) {
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
        
        // If pool is closed, don't process the return - just discard
        guard !isClosed else {
            totalCreated -= 1
            return
        }
        
        // Validate resource
        let isValid = await resource.validate()
        guard isValid else {
            // Resource is invalid - discard it
            totalCreated -= 1
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
            // Cancellation during cleanup - check if pool still open
            guard !isClosed else {
                totalCreated -= 1
                return
            }
            
            // Pool still open - return resource despite cancellation
            _metrics.recordSuccessfulReturn()
            handOffOrReturnResource(resource)
            
        } catch {
            // Actual reset failure - discard resource
            totalCreated -= 1
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
        // Remove expired waiters first
        waitQueue.removeAll { $0.isExpired }
        
        // If there's a waiter, hand off directly (FIFO for fairness)
        if let waiter = waitQueue.first {
            waitQueue.removeFirst()
            leased.insert(ObjectIdentifier(resource))
            _metrics.recordDirectHandoff()
            
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
        
        do {
            let resource = try await factory.create()
            totalCreated += 1
            
            // Hand off to next waiter
            if let waiter = waitQueue.first {
                waitQueue.removeFirst()
                leased.insert(ObjectIdentifier(resource))
                waiter.continuation.resume(returning: resource)
            } else {
                available.append(resource)
            }
        } catch {
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
    
    // MARK: - Debug Support
    
    #if DEBUG
    /// Verify accounting invariant: available + leased = totalCreated
    ///
    /// NOTE: This should only be called when the pool is quiescent (no operations in-flight).
    private func verifyAccounting() {
        let actual = available.count + leased.count
        assert(actual == totalCreated,
               """
               Accounting mismatch:
                 available: \(available.count)
                 leased: \(leased.count)
                 sum: \(actual)
                 totalCreated: \(totalCreated)
               """)
    }
    
    /// Test helper: Verify accounting at a quiescent point
    internal func testVerifyAccounting() {
        verifyAccounting()
    }
    #else
    private func verifyAccounting() {}
    #endif
    
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
        waitQueueDepth: 0
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
}

// MARK: - Duration Extensions

extension Duration {
    fileprivate static func / (lhs: Duration, rhs: Int) -> Duration {
        let nanoseconds = lhs.components.seconds * 1_000_000_000 + lhs.components.attoseconds / 1_000_000_000
        let avgNanoseconds = nanoseconds / Int64(rhs)
        return .nanoseconds(avgNanoseconds)
    }
}
