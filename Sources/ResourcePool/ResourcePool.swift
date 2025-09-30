import Foundation

// MARK: - Lease (Internal Only)

/// Resource lease with explicit return via `use()`
///
/// INTERNAL: This type is an implementation detail and should not be exposed publicly.
/// Use `withResource()` instead, which provides automatic cleanup even on cancellation.
internal struct Lease<Resource: PoolableResource>: ~Copyable, Sendable {
    private let resource: Resource
    private let pool: ResourcePool<Resource>
#if DEBUG
    private let acquisitionLocation: String
#endif
    
    internal init(resource: Resource, pool: ResourcePool<Resource>) {
        self.resource = resource
        self.pool = pool
#if DEBUG
        self.acquisitionLocation = "\(#file):\(#line)"
#endif
    }
    
    /// Use the resource and automatically return it to the pool
    internal consuming func use<T>(
        _ operation: (Resource) async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation(resource)
            await pool.release(resource)
            return result
        } catch {
            await pool.release(resource)
            throw error
        }
    }
    
    deinit {
#if DEBUG
        print("⚠️ WARNING: Lease destroyed without calling use() - resource leaked")
        print("  Acquired at: \(acquisitionLocation)")
        print("  This is a programming error - always call use() on leases")
#endif
    }
}

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

// MARK: - Resource Pool

/// A thread-safe, actor-based resource pool with automatic lifecycle management
///
/// # Features
/// - Lazy resource creation up to configured capacity
/// - Optional warmup to pre-create resources
/// - Automatic validation and reset on return
/// - Timeout support for acquisition
/// - Graceful degradation when resources fail
/// - Cancellation-safe resource usage via `withResource()`
/// - Production metrics tracking
///
/// # Important Notes
/// - Resources MUST be reference types (classes/actors)
/// - Always use `withResource()` for resource access - it provides automatic cleanup
/// - Resources are validated and reset after each use
/// - Failed resources are discarded and lazily recreated
/// - Performance may degrade with >30 concurrent waiters (thundering herd on notifications)
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
    
    /// ObjectIdentifiers of resources currently leased
    private var leased: Set<ObjectIdentifier> = []
    
    /// Maximum resources to create
    private let capacity: Int
    
    /// Factory for creating resources
    private let factory: ResourceFactory<Resource>
    
    /// Total resources created (to enforce capacity)
    private var totalCreated: Int = 0
    
    /// Stream for availability notifications (carries Void, not resources)
    private let availabilityStream: AsyncStream<Void>
    private let availabilityContinuation: AsyncStream<Void>.Continuation
    
    /// Available resources waiting to be acquired
    private var available: [Resource] = []
    
    /// Whether pool is closed
    private var isClosed = false
    
    /// Metrics for observability
    private var _metrics = Metrics()
    
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
        
        // Set up availability notification stream
        var cont: AsyncStream<Void>.Continuation!
        self.availabilityStream = AsyncStream { continuation in
            cont = continuation
        }
        self.availabilityContinuation = cont
        
        // Pre-create resources if warmup enabled
        if warmup {
            for _ in 0..<capacity {
                do {
                    let resource = try await factory.create()
                    available.append(resource)
                    totalCreated += 1
                } catch {
                    // If warmup fails, we still want to create the pool
                    // but with fewer resources. Log the error and continue.
                    _metrics.recordCreationFailure()
                    throw PoolError.creationFailed("Warmup failed: \(error)")
                }
            }
        }
        
        // Only verify at initialization - pool is quiescent
        verifyAccounting()
    }
    
    // MARK: - Public API
    
    /// Use a resource with automatic cleanup, even on cancellation
    ///
    /// This is the recommended and only safe way to use pool resources.
    /// The resource is automatically returned to the pool when the operation
    /// completes, fails, or is cancelled.
    ///
    /// **Cancellation Safety:** This method guarantees resource cleanup even when cancelled.
    /// Actor-isolated cleanup methods complete atomically before cancellation propagates.
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
        
        // Acquire resource
        let resource = try await acquireResource(timeout: timeout)
        
        let acquisitionDuration = ContinuousClock.now - acquisitionStart
        _metrics.recordAcquisition(waitTime: acquisitionDuration)
        
        // Use with automatic cleanup on any exit path
        // CRITICAL: Direct await (not Task) ensures cleanup completes even on cancellation
        do {
            let result = try await operation(resource)
            await release(resource)
            // Note: We don't verify accounting here because concurrent operations
            // may still be in-flight, creating false positives
            return result
        } catch {
            // Actor-isolated release() completes atomically before cancellation propagates
            await release(resource)
            throw error
        }
    }
    
    /// Get current pool statistics
    ///
    /// Note: This returns a point-in-time snapshot. Values may change
    /// immediately after being read due to concurrent operations.
    public var statistics: Statistics {
        Statistics(
            available: available.count,
            leased: leased.count,
            capacity: capacity
        )
    }
    
    /// Get current pool metrics
    ///
    /// Provides observability into pool behavior for monitoring and debugging.
    public var metrics: Metrics {
        var metricsSnapshot = _metrics
        metricsSnapshot.currentStatistics = statistics
        return metricsSnapshot
    }
    
    /// Drain the pool gracefully and close it
    ///
    /// This method:
    /// 1. Stops accepting new acquisitions (sets `isClosed`)
    /// 2. Waits for all leased resources to be returned (up to timeout)
    /// 3. Closes the pool and clears all state
    ///
    /// Use this for graceful shutdown to ensure all resources are properly returned.
    ///
    /// - Parameter timeout: Maximum time to wait for resources to be returned
    /// - Throws: `PoolError.drainTimeout` if timeout expires with resources still leased
    public func drain(timeout: Duration = .seconds(30)) async throws {
        isClosed = true
        
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
    /// currently leased will NOT be waited for - they will be orphaned when
    /// returned. For graceful shutdown, use `drain()` instead.
    ///
    /// After closing:
    /// - New acquisitions will fail with `PoolError.closed`
    /// - Availability stream is terminated
    /// - All internal state is cleared
    public func close() async {
        isClosed = true
        availabilityContinuation.finish()
        available.removeAll()
        leased.removeAll()
        totalCreated = 0
        
        // Safe to verify - pool is now closed and quiescent
        verifyAccounting()
    }
    
    // MARK: - Internal Implementation
    
    /// Internal: Acquire a resource (used by withResource)
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
        
        // WAIT: Pool exhausted, wait for availability with timeout
        // NOTE: This creates a "thundering herd" when resources become available.
        // All waiters wake, race to acquire, and only one succeeds. Performance
        // degrades with >30 concurrent waiters. For higher concurrency, consider
        // a queue-based waiter system.
        let resource = try await withThrowingTaskGroup(of: Resource?.self) { group in
            // Task 1: Wait for availability notification
            group.addTask {
                for await _ in self.availabilityStream {
                    if let resource = await self.tryTakeAvailable() {
                        return resource
                    }
                }
                return nil
            }
            
            // Task 2: Timeout
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            
            defer { group.cancelAll() }
            
            guard let result = try await group.next() else {
                throw PoolError.closed
            }
            
            guard let resource = result else {
                self._metrics.recordTimeout()
                throw PoolError.timeout
            }
            
            return resource
        }
        
        leased.insert(ObjectIdentifier(resource))
        return resource
    }
    
    /// Try to take an available resource (called by waiters)
    private func tryTakeAvailable() -> Resource? {
        available.popLast()
    }
    
    /// Internal: Release a resource back to the pool
    fileprivate func release(_ resource: Resource) async {
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
            return
        }
        
        // Reset resource - ignore cancellation during cleanup
        do {
            try await resource.reset()
            
            // Check again if pool was closed during reset
            guard !isClosed else {
                totalCreated -= 1
                return
            }
            
            // Return to available pool (LIFO - good for cache locality with WKWebView)
            available.append(resource)
            _metrics.recordSuccessfulReturn()
            // Notify waiters that a resource is available
            availabilityContinuation.yield(())
        } catch is CancellationError {
            // Cancellation during cleanup - check if pool still open
            guard !isClosed else {
                totalCreated -= 1
                return
            }
            
            // Pool still open - return resource despite cancellation
            available.append(resource)
            _metrics.recordSuccessfulReturn()
            availabilityContinuation.yield(())
        } catch {
            // Actual reset failure - discard resource
            totalCreated -= 1
            _metrics.recordResetFailure()
        }
    }
    
    // MARK: - Debug Support
    
#if DEBUG
    /// Verify accounting invariant: available + leased = totalCreated
    ///
    /// NOTE: This should only be called when the pool is quiescent (no operations in-flight).
    /// Calling this during concurrent operations will produce false positives due to resources
    /// being temporarily in neither 'available' nor 'leased' during async release operations.
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
    /// Only call this after ensuring all concurrent operations have completed
    internal func testVerifyAccounting() {
        verifyAccounting()
    }
#else
    private func verifyAccounting() {}
#endif
    
    // MARK: - Testing Support (Internal)
    
#if DEBUG
    /// Internal: Acquire a resource with manual lifecycle (for testing only)
    /// DO NOT USE IN PRODUCTION - use withResource() instead
    internal func acquire(timeout: Duration = .seconds(30)) async throws -> Lease<Resource> {
        let resource = try await acquireResource(timeout: timeout)
        return Lease(resource: resource, pool: self)
    }
#endif
    
    deinit {
        availabilityContinuation.finish()
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
    
    /// Alias for leased count
    public var inUse: Int { leased }
    
    /// Current utilization as a percentage (0.0 to 1.0)
    public var utilization: Double {
        guard capacity > 0 else { return 0 }
        return Double(leased) / Double(capacity)
    }
}

// MARK: - Metrics

/// Production metrics for pool observability
public struct Metrics: Sendable {
    /// Current pool state snapshot
    public var currentStatistics: Statistics = Statistics(available: 0, leased: 0, capacity: 0)
    
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
    
    /// Total wait time across all acquisitions
    private var totalWaitTime: Duration = .zero
    
    /// Average wait time for resource acquisition
    public var averageWaitTime: Duration? {
        guard totalAcquisitions > 0 else { return nil }
        return totalWaitTime / totalAcquisitions
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
}

extension Duration {
    fileprivate static func / (lhs: Duration, rhs: Int) -> Duration {
        let nanoseconds = lhs.components.seconds * 1_000_000_000 + lhs.components.attoseconds / 1_000_000_000
        let avgNanoseconds = nanoseconds / Int64(rhs)
        return .nanoseconds(avgNanoseconds)
    }
}
