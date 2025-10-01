import Foundation
@testable import ResourcePool

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

// MARK: - Failing Resource

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
        try await Task.sleep(for: .milliseconds(50))
        return DatabaseConnection()
    }

    func validate() async -> Bool {
        true
    }

    func reset() async throws {
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

// MARK: - Test Utilities

extension Duration {
    func formatted() -> String {
        let totalNanos = components.seconds * 1_000_000_000 +
                        components.attoseconds / 1_000_000_000
        
        if totalNanos < 1_000_000 {
            return "\(totalNanos) ns"
        } else if totalNanos < 1_000_000_000 {
            return String(format: "%.2f ms", Double(totalNanos) / 1_000_000)
        } else {
            return String(format: "%.2f s", Double(totalNanos) / 1_000_000_000)
        }
    }
}

extension Duration: Comparable {
    public static func < (lhs: Duration, rhs: Duration) -> Bool {
        let lhsNanos = lhs.components.seconds * 1_000_000_000 +
                      lhs.components.attoseconds / 1_000_000_000
        let rhsNanos = rhs.components.seconds * 1_000_000_000 +
                      rhs.components.attoseconds / 1_000_000_000
        return lhsNanos < rhsNanos
    }
}
