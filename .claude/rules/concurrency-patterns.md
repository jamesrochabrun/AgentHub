# Concurrency Patterns

Swift concurrency patterns for AgentHub. We use async/await and actors exclusively.

## Core Rules

1. **NO Combine** - Use async/await instead
2. **Services are actors** - For thread safety
3. **Models are Sendable** - For safe passing across boundaries
4. **MainActor for UI** - All UI updates on main thread

## Actor Pattern

```swift
public actor MyService {
  private var cache: [String: Data] = [:]

  public func getData(for key: String) async -> Data? {
    return cache[key]
  }

  public func setData(_ data: Data, for key: String) async {
    cache[key] = data
  }
}
```

## Sendable Models

```swift
public struct MyModel: Sendable, Codable, Identifiable {
  public let id: String
  public let name: String
  public let timestamp: Date
}
```

## MainActor Usage

### For UI State
```swift
@MainActor
@Observable
final class MyViewModel {
  var items: [Item] = []

  func load() async {
    let items = await service.fetchItems()
    self.items = items  // Safe - already on MainActor
  }
}
```

### Explicit MainActor Call
```swift
func processInBackground() async {
  let result = await heavyComputation()
  await MainActor.run {
    self.updateUI(with: result)
  }
}
```

## Task Groups

### Parallel Execution
```swift
func fetchAll() async throws -> [Result] {
  try await withThrowingTaskGroup(of: Result.self) { group in
    for id in ids {
      group.addTask {
        try await self.fetch(id: id)
      }
    }

    var results: [Result] = []
    for try await result in group {
      results.append(result)
    }
    return results
  }
}
```

### With Timeout
```swift
func fetchWithTimeout() async throws -> Data {
  try await withThrowingTaskGroup(of: Data.self) { group in
    group.addTask { try await self.fetch() }
    group.addTask {
      try await Task.sleep(for: .seconds(30))
      throw TimeoutError()
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}
```

## Async Sequences

```swift
for try await line in fileHandle.bytes.lines {
  process(line)
}
```

## Common Mistakes to Avoid

### Wrong: Using Combine
```swift
// DON'T
publisher.sink { value in }
```

### Right: Using async/await
```swift
// DO
let value = await service.getValue()
```

### Wrong: Non-Sendable in actor
```swift
// DON'T
public actor MyService {
  var delegate: SomeDelegate?  // Not Sendable!
}
```

### Right: Sendable types only
```swift
// DO
public actor MyService {
  var callback: (@Sendable (Result) -> Void)?
}
```
