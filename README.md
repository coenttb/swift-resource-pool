# swift-resource-pool

[![CI](https://github.com/coenttb/swift-resource-pool/workflows/CI/badge.svg)](https://github.com/coenttb/swift-resource-pool/actions/workflows/ci.yml)
![Development Status](https://img.shields.io/badge/status-active--development-blue.svg)

Actor-based resource pool for Swift with thread-safe pooling, FIFO fairness, and automatic resource management.

## Table of Contents

- [Overview](#overview)
- [Why swift-resource-pool?](#why-swift-resource-pool)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
- [Real-World Examples](#real-world-examples)
- [Performance Characteristics](#performance-characteristics)
- [API Reference](#api-reference)
- [Advanced Usage](#advanced-usage)
- [Error Handling](#error-handling)
- [Requirements](#requirements)
- [Related Packages](#related-packages)
- [Dependencies](#dependencies)
- [Contributing](#contributing)
- [License](#license)

## Overview

**swift-resource-pool** provides a generic, high-performance resource pooling solution built with Swift's actor model. It eliminates the thundering herd problem through direct resource handoff, ensures fairness with FIFO ordering, and offers comprehensive metrics for production monitoring.

```swift
import ResourcePool

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
```

## Key Features

### Efficient Resource Handoff
- Direct handoff to exactly one waiting task without broadcast storms
- O(1) wakeup efficiency with 90-95% direct handoff rate under sustained load
- Linear scalability up to 200+ concurrent waiters without performance degradation

### Fairness and Reliability
- FIFO queue ensures waiters are served in arrival order
- Guaranteed cleanup even during task cancellation
- Thread-safe actor-isolated implementation without locks
- Comprehensive production metrics for utilization tracking

### Performance Characteristics
- Lazy resource creation on-demand up to capacity limits
- Optional warmup for pre-created resources
- Automatic validation and reset between resource uses
- Per-waiter efficient timeout deadlines
- 45 test scenarios with proven stability

## Quick Start

### Installation

Add swift-resource-pool to your Swift package:

```swift
dependencies: [
    .package(url: "https://github.com/coenttb/swift-resource-pool", from: "0.1.0")
]
```

For Xcode projects, add the package URL: `https://github.com/coenttb/swift-resource-pool`

### Your First Resource Pool

```swift
import ResourcePool

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
```

## Core Concepts

### 🏗️ Poolable Resources

Resources must conform to `PoolableResource` protocol:

```swift
public protocol PoolableResource: Sendable, AnyObject {
    associatedtype Config: Sendable
    
    /// Create a new resource instance
    static func create(config: Config) async throws -> Self
    
    /// Check if the resource is still valid and can be reused
    func validate() async -> Bool
    
    /// Reset the resource to a clean state for reuse
    func reset() async throws
}
```

**Important**: Resources MUST be reference types (classes or actors) because the pool tracks them using `ObjectIdentifier`.

### 🔄 Resource Lifecycle

```swift
// Pool manages complete lifecycle:
// 1. Create (lazy or warmup)
let resource = try await factory.create()

// 2. Acquire (immediate or wait)
let resource = try await pool.withResource { resource in
    // 3. Use safely
    try await resource.performWork()
    // 4. Validate after use
    let isValid = await resource.validate()
    // 5. Reset for reuse
    try await resource.reset()
    // 6. Return to pool or discard
}
```

### 📊 Pool Statistics

Monitor pool behavior in real-time:

```swift
let stats = await pool.statistics
print("Available: \(stats.available)")
print("Leased: \(stats.leased)")
print("Utilization: \(stats.utilization * 100)%")
print("Queue depth: \(stats.waitQueueDepth)")
print("Backpressure: \(stats.hasBackpressure)")

let metrics = await pool.metrics
print("Total acquisitions: \(metrics.totalAcquisitions)")
print("Timeouts: \(metrics.timeouts)")
print("Handoff rate: \(metrics.handoffRate * 100)%")
print("Avg wait time: \(metrics.averageWaitTime?.formatted() ?? "N/A")")
```

## Real-World Examples

### 🗄️ Database Connection Pool

```swift
import PostgresNIO

actor PostgresConnection: PoolableResource {
    struct Config: Sendable {
        let host: String
        let port: Int
        let database: String
        let user: String
        let password: String
    }
    
    private var connection: PostgresConnection?
    
    static func create(config: Config) async throws -> PostgresConnection {
        let conn = try await PostgresConnection.connect(
            host: config.host,
            port: config.port,
            username: config.user,
            password: config.password,
            database: config.database
        )
        return PostgresConnection(connection: conn)
    }
    
    func validate() async -> Bool {
        guard let connection else { return false }
        return !connection.isClosed
    }
    
    func reset() async throws {
        // Rollback any uncommitted transactions
        try await connection?.query("ROLLBACK")
    }
    
    func query<T>(_ sql: String) async throws -> [T] {
        // Execute query
    }
}

// Create pool
let dbPool = try await ResourcePool<PostgresConnection>(
    capacity: 20,
    resourceConfig: .init(
        host: "localhost",
        port: 5432,
        database: "myapp",
        user: "postgres",
        password: "password"
    )
)

// Use in your application
struct UserRepository {
    let pool: ResourcePool<PostgresConnection>
    
    func fetchUser(id: UUID) async throws -> User? {
        try await pool.withResource(timeout: .seconds(5)) { conn in
            try await conn.query("SELECT * FROM users WHERE id = \(id)")
        }
    }
}
```

### 🌐 HTTP Client Pool

```swift
import Foundation

actor HTTPClient: PoolableResource {
    struct Config: Sendable {
        let timeout: TimeInterval
    }
    
    private let session: URLSession
    
    static func create(config: Config) async throws -> HTTPClient {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = config.timeout
        return HTTPClient(session: URLSession(configuration: configuration))
    }
    
    func validate() async -> Bool {
        return true
    }
    
    func reset() async throws {
        session.invalidateAndCancel()
    }
    
    func fetch(url: URL) async throws -> Data {
        let (data, _) = try await session.data(from: url)
        return data
    }
}

// Create pool for API clients
let httpPool = try await ResourcePool<HTTPClient>(
    capacity: 10,
    resourceConfig: .init(timeout: 30)
)

// Make requests with automatic pooling
let data = try await httpPool.withResource { client in
    try await client.fetch(url: apiURL)
}
```

### 📄 WKWebView Pool (PDF Generation)

```swift
#if canImport(WebKit)
import WebKit

actor WebViewResource: PoolableResource {
    struct Config: Sendable {}
    
    private var webView: WKWebView!
    
    static func create(config: Config) async throws -> WebViewResource {
        return await WebViewResource()
    }
    
    @MainActor
    init() {
        self.webView = WKWebView()
    }
    
    func validate() async -> Bool {
        return webView != nil
    }
    
    func reset() async throws {
        await MainActor.run {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
    }
    
    func renderPDF(html: String) async throws -> Data {
        // Render HTML to PDF
    }
}

// Pool for PDF generation
let pdfPool = try await ResourcePool<WebViewResource>(
    capacity: 3,
    resourceConfig: .init(),
    warmup: true
)

// Generate PDFs with pooled WebViews
let pdfData = try await pdfPool.withResource { webView in
    try await webView.renderPDF(html: invoiceHTML)
}
#endif
```

## Performance Characteristics

Based on comprehensive test suite with 45 scenarios:

### Throughput Benchmarks

| Pool Capacity | Concurrent Tasks | Total Ops | Throughput | Avg Wait |
|--------------|------------------|-----------|------------|----------|
| 2            | 10               | 200       | 277 ops/s  | 28.1ms   |
| 5            | 30               | 300       | 646 ops/s  | 36.8ms   |
| 10           | 50               | 500       | 1,267 ops/s| 30.0ms   |
| 20           | 100              | 500       | 2,395 ops/s| 30.1ms   |

### Scalability Results

| Concurrent Waiters | Duration | Ops/Sec | Max Queue | Handoff Rate |
|--------------------|----------|---------|-----------|--------------|
| 10                 | 1.06s    | 9.4     | 0         | 0.0%         |
| 30                 | 1.07s    | 28.1    | 20        | 66.7%        |
| 50                 | 1.09s    | 45.9    | 40        | 80.0%        |
| 100                | 1.09s    | 92.1    | 90        | 90.0%        |
| 200                | 1.09s    | 183.8   | 190       | 95.0%        |

**Key Insights:**
- ✅ Linear scalability up to 200 concurrent waiters
- ✅ Zero timeouts even under extreme load (500 concurrent ops)
- ✅ High handoff rate (90%+) indicates efficient queue management
- ✅ Consistent throughput with minimal degradation

### Latency Distribution (Under Contention)

Pool capacity: 5, Concurrent ops: 200

| Percentile | Latency  |
|------------|----------|
| Min        | 15.9ms   |
| P50        | 160.9ms  |
| P90        | 165.7ms  |
| P95        | 167.0ms  |
| P99        | 167.9ms  |
| Max        | 167.9ms  |
| Avg        | 143.8ms  |

**P99/Avg ratio: 1.2x** (excellent tail latency)

## API Reference

### Initialization

```swift
init(
    capacity: Int,
    resourceConfig: Resource.Config,
    warmup: Bool = true
) async throws
```

**Parameters:**
- `capacity`: Maximum resources to create (must be > 0)
- `resourceConfig`: Configuration for creating resources
- `warmup`: If true, pre-create all resources; if false, create lazily

### Core Methods

```swift
// Use a resource with automatic cleanup
func withResource<T>(
    timeout: Duration = .seconds(30),
    _ operation: (Resource) async throws -> T
) async throws -> T

// Get current pool state
var statistics: Statistics { get async }

// Get production metrics
var metrics: Metrics { get async }

// Graceful shutdown
func drain(timeout: Duration = .seconds(30)) async throws

// Immediate shutdown
func close() async
```

### Statistics

```swift
struct Statistics: Sendable, Equatable {
    let available: Int           // Resources ready for use
    let leased: Int             // Resources currently in use
    let capacity: Int           // Maximum pool capacity
    let waitQueueDepth: Int     // Tasks waiting for resources
    
    var inUse: Int              // Alias for leased
    var utilization: Double     // 0.0 to 1.0
    var hasBackpressure: Bool   // Queue depth > 0
}
```

### Metrics

```swift
struct Metrics: Sendable {
    let currentStatistics: Statistics
    let totalAcquisitions: Int
    let timeouts: Int
    let validationFailures: Int
    let resetFailures: Int
    let creationFailures: Int
    let successfulReturns: Int
    let waitersQueued: Int
    let directHandoffs: Int
    
    var averageWaitTime: Duration?
    var handoffRate: Double
}
```

## Advanced Usage

### Handling Failures

```swift
// Resource that can fail validation
actor UnreliableResource: PoolableResource {
    struct Config: Sendable {}
    private var failureCount = 0
    
    func validate() async -> Bool {
        // Simulate intermittent failures
        failureCount += 1
        return failureCount % 5 != 0
    }
    
    // Pool automatically discards invalid resources
}
```

### Custom Timeouts

```swift
// Short timeout for quick operations
let fastResult = try await pool.withResource(timeout: .seconds(1)) { resource in
    try await resource.quickOperation()
}

// Long timeout for expensive operations
let slowResult = try await pool.withResource(timeout: .seconds(60)) { resource in
    try await resource.expensiveOperation()
}
```

### Monitoring and Observability

```swift
// Periodic monitoring
Task {
    while !Task.isCancelled {
        let stats = await pool.statistics
        let metrics = await pool.metrics
        
        logger.info("Pool stats", metadata: [
            "available": .string(String(stats.available)),
            "leased": .string(String(stats.leased)),
            "utilization": .string(String(format: "%.1f%%", stats.utilization * 100)),
            "queue_depth": .string(String(stats.waitQueueDepth)),
            "handoff_rate": .string(String(format: "%.1f%%", metrics.handoffRate * 100))
        ])
        
        try await Task.sleep(for: .seconds(30))
    }
}
```

### Graceful Shutdown

```swift
// Application shutdown
func shutdown() async throws {
    do {
        // Wait for active operations to complete
        try await pool.drain(timeout: .seconds(30))
        logger.info("Pool drained successfully")
    } catch PoolError.drainTimeout {
        logger.warning("Pool drain timed out, some resources still leased")
        // Force close if needed
        await pool.close()
    }
}
```

### Sharing Pools Globally

**IMPORTANT:** For system-limited resources (WebViews, database connections, file handles), creating multiple pool instances can lead to resource exhaustion. Use a global actor to ensure a single shared pool:

```swift
// ❌ BAD: Each operation creates its own pool
func generatePDF(html: String) async throws -> Data {
    let pool = try await ResourcePool<WKWebViewResource>(capacity: 8, ...)
    // Problem: 7 parallel calls = 56 WebViews trying to initialize!
    return try await pool.withResource { ... }
}

// ✅ GOOD: Single shared pool via global actor
@globalActor
public actor WebViewPoolActor {
    public static let shared = WebViewPoolActor()

    private var sharedPool: ResourcePool<WKWebViewResource>?

    public func getPool() async throws -> ResourcePool<WKWebViewResource> {
        if let existing = sharedPool {
            return existing
        }

        let pool = try await ResourcePool<WKWebViewResource>(
            capacity: 8,
            resourceConfig: .default,
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
```

**Why this matters:**
- 7 parallel operations × 8 WebViews each = **56 WebViews** (exhausts system)
- 7 parallel operations sharing 1 pool of 8 = **8 WebViews** (graceful queueing)
- **56x improvement** in test performance (76s → 1.4s)
- Proper FIFO queueing ensures fairness
- One warmup cost amortized across all users

**When NOT to share:**
- Different resource configurations needed
- Isolated testing scenarios
- Short-lived, bounded workloads
- Resources with incompatible lifecycles

### Multiple Pools

Each `ResourcePool` is independent. When running multiple pools of **different types**, consider your total system resource budget:

```swift
// Each pool maxes out independently
let dbPool = ResourcePool<DatabaseConnection>(capacity: 10)    // ~100MB
let httpPool = ResourcePool<HTTPClient>(capacity: 20)          // ~100MB
let webViewPool = ResourcePool<WKWebView>(capacity: 3)         // ~600MB
// Total: ~800MB
```

## Error Handling

```swift
public enum PoolError: Error, Sendable, Equatable {
    case timeout                    // Acquisition timeout expired
    case closed                     // Pool is closed
    case creationFailed(String)     // Resource creation failed
    case resetFailed(String)        // Resource reset failed
    case drainTimeout               // Drain timeout with leased resources
}
```

## Requirements

- Swift 5.9+ (Swift 6.0 language mode for strict concurrency)
- Platforms:
  - macOS 14+
  - iOS 17+
  - tvOS 17+
  - watchOS 10+

## Related Packages

### Used By

- [swift-html-to-pdf](https://github.com/coenttb/swift-html-to-pdf): The Swift package for printing HTML to PDF.

## Dependencies

This package has **zero external dependencies** - it only uses Foundation and Swift standard library.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

## Support

- **[Issue Tracker](https://github.com/coenttb/swift-resource-pool/issues)** - Report bugs or request features
- **[Discussions](https://github.com/coenttb/swift-resource-pool/discussions)** - Ask questions and share ideas
- **[Newsletter](http://coenttb.com/en/newsletter/subscribe)** - Stay updated
- **[X (Twitter)](http://x.com/coenttb)** - Follow for updates
- **[LinkedIn](https://www.linkedin.com/in/tenthijeboonkkamp)** - Connect professionally

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

---

<p align="center">
  Made by <a href="https://coenttb.com">coenttb</a>
</p>
