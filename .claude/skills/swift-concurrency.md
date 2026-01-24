# Swift Concurrency Patterns

Reference for Swift concurrency in AgentHub.

## Core Concepts

### Actors
Thread-safe isolation for mutable state.

```swift
public actor DataStore {
  private var items: [Item] = []

  public func add(_ item: Item) {
    items.append(item)
  }

  public func getAll() -> [Item] {
    return items
  }
}
```

### Sendable
Types safe to pass across concurrency boundaries.

```swift
// Value types are usually Sendable
public struct MyModel: Sendable {
  let id: String
  let name: String
}

// Reference types need explicit conformance
public final class MyClass: Sendable {
  let immutableValue: String  // OK - immutable
}
```

### MainActor
For UI-related code that must run on main thread.

```swift
@MainActor
@Observable
final class ViewModel {
  var items: [Item] = []

  func load() async {
    items = await service.fetchItems()
  }
}
```

## Async/Await Patterns

### Basic Async Function
```swift
func fetchData() async throws -> Data {
  let (data, _) = try await URLSession.shared.data(from: url)
  return data
}
```

### Calling Async from Sync
```swift
func buttonTapped() {
  Task {
    await viewModel.load()
  }
}
```

### Parallel Execution
```swift
async let result1 = fetchFirst()
async let result2 = fetchSecond()
let (r1, r2) = await (result1, result2)
```

### Task Groups
```swift
func fetchAll(ids: [String]) async throws -> [Item] {
  try await withThrowingTaskGroup(of: Item.self) { group in
    for id in ids {
      group.addTask {
        try await self.fetch(id: id)
      }
    }

    var items: [Item] = []
    for try await item in group {
      items.append(item)
    }
    return items
  }
}
```

## Common Patterns

### Actor with Async Initialization
```swift
public actor MyService {
  private var cache: Cache?

  public func initialize() async {
    cache = await Cache.load()
  }
}
```

### Timeout Pattern
```swift
func withTimeout<T>(
  seconds: Double,
  operation: @escaping () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw TimeoutError()
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}
```

### Cancellation Handling
```swift
func longOperation() async throws {
  for item in items {
    try Task.checkCancellation()
    await process(item)
  }
}
```

## Anti-Patterns to Avoid

### Don't Block Actors
```swift
// BAD
public actor BadService {
  func blocking() {
    Thread.sleep(forTimeInterval: 5)  // Blocks actor
  }
}

// GOOD
public actor GoodService {
  func nonBlocking() async {
    try? await Task.sleep(for: .seconds(5))
  }
}
```

### Don't Use Combine
```swift
// BAD (in this codebase)
publisher.sink { value in }

// GOOD
let value = await service.getValue()
```

### Don't Ignore MainActor
```swift
// BAD
func updateUI() {
  label.text = "Updated"  // May not be on main thread
}

// GOOD
@MainActor
func updateUI() {
  label.text = "Updated"  // Guaranteed main thread
}
```

## Debugging

### Check Current Actor
```swift
#if DEBUG
print("On MainActor: \(Thread.isMainThread)")
#endif
```

### Task Priority
```swift
Task(priority: .userInitiated) {
  await highPriorityWork()
}

Task(priority: .background) {
  await lowPriorityWork()
}
```
