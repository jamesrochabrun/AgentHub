# Service Patterns

Standard patterns for services in AgentHub.

## Creating a Service

### Actor-Based Service (Preferred)
```swift
// Services/MyService.swift
import Foundation

public actor MyService {

  public init() { }

  public func doWork() async throws -> Result {
    // Implementation
  }
}
```

### Adding to Provider
```swift
// Configuration/AgentHubProvider.swift
public private(set) lazy var myService: MyService = { MyService() }()
```

## Error Handling

```swift
public enum MyServiceError: LocalizedError, Sendable {
  case operationFailed(String)
  case notFound(String)
  case timeout

  public var errorDescription: String? {
    switch self {
    case .operationFailed(let message):
      return "Operation failed: \(message)"
    case .notFound(let item):
      return "Not found: \(item)"
    case .timeout:
      return "Operation timed out"
    }
  }
}
```

## Logging

```swift
import os

// Use AppLogger subsystems
AppLogger.git.info("Starting operation")
AppLogger.git.error("Operation failed: \(error)")
```

## Async Patterns

### Basic Async Function
```swift
public func fetchData() async throws -> Data {
  // Implementation
}
```

### With Timeout
```swift
public func fetchWithTimeout() async throws -> Data {
  try await withThrowingTaskGroup(of: Data.self) { group in
    group.addTask {
      // Main work
    }
    group.addTask {
      try await Task.sleep(for: .seconds(30))
      throw MyServiceError.timeout
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}
```

## Process Execution

```swift
private func runCommand(_ args: [String]) async throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = args

  let outputPipe = Pipe()
  process.standardOutput = outputPipe

  try process.run()
  process.waitUntilExit()

  let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
  return String(data: data, encoding: .utf8) ?? ""
}
```

## Rules

1. Services MUST be actors or @unchecked Sendable
2. Use async/await, NOT Combine
3. Include proper error types
4. Use AppLogger for debugging
5. Add to AgentHubProvider for injection
