# Performance Smoke Test

Quick performance checks before shipping.

## When to Use

- After implementing new features
- Before major releases
- When performance issues reported

## Quick Checks

### 1. Build Time
```bash
# Clean build time
time xcodebuild -project app/AgentHub.xcodeproj -scheme AgentHub clean build

# Should complete in reasonable time
# Flag if > 2 minutes for incremental build
```

### 2. App Launch
- Cold launch should be < 2 seconds
- Warm launch should be < 1 second
- No visible stutter on launch

### 3. Memory Usage
- Monitor in Activity Monitor
- Baseline: < 100MB for idle
- No memory growth over time (leaks)

### 4. CPU Usage
- Idle should be < 1% CPU
- Active operations should complete
- No runaway CPU usage

## Code-Level Checks

### SwiftUI Performance

```swift
// AVOID: Expensive operations in body
var body: some View {
  // Don't do heavy computation here
  let result = expensiveOperation()  // BAD
  Text(result)
}

// PREFER: Compute elsewhere
var body: some View {
  Text(cachedResult)  // GOOD
}
```

### Lazy Loading

```swift
// GOOD: Use LazyVStack for large lists
ScrollView {
  LazyVStack {
    ForEach(items) { item in
      ItemRow(item: item)
    }
  }
}

// BAD: VStack loads all items immediately
ScrollView {
  VStack {
    ForEach(items) { item in  // Loads ALL items
      ItemRow(item: item)
    }
  }
}
```

### Actor Contention

```swift
// AVOID: Too many awaits on same actor
for item in items {
  await actor.process(item)  // Serial, slow
}

// PREFER: Batch operations
await actor.processAll(items)  // Single await
```

### Image Loading

```swift
// GOOD: Async image loading
AsyncImage(url: imageURL) { image in
  image.resizable()
} placeholder: {
  ProgressView()
}

// BAD: Synchronous loading in body
Image(uiImage: UIImage(data: loadSync())!)
```

## Performance Red Flags

| Issue | Symptom | Fix |
|-------|---------|-----|
| Main thread blocking | UI freezes | Move to background |
| Memory leak | Growing memory | Check retain cycles |
| Excessive redraws | Stuttering | Optimize view hierarchy |
| Actor contention | Slow operations | Batch or reduce calls |
| Large lists | Slow scrolling | Use LazyVStack |

## Smoke Test Checklist

- [ ] App launches in < 2 seconds
- [ ] No visible stutter during normal use
- [ ] Memory stable over 5 minutes of use
- [ ] CPU idle when not active
- [ ] Lists scroll smoothly
- [ ] No blocking operations on main thread

## Report Format

```markdown
## Performance Smoke Test: <Feature>

### Launch Time
- Cold: Xs
- Warm: Xs
- Verdict: PASS/FAIL

### Memory
- Baseline: XMB
- After 5min: XMB
- Verdict: PASS/FAIL

### CPU
- Idle: X%
- Active: X%
- Verdict: PASS/FAIL

### UI Responsiveness
- Scrolling: Smooth/Stuttering
- Transitions: Smooth/Stuttering
- Verdict: PASS/FAIL

**Overall: PASS/FAIL**
```
