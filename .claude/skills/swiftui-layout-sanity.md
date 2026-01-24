# SwiftUI Layout Sanity Check

Quick sanity checks for SwiftUI layout issues.

## When to Use

- Debugging layout issues
- Reviewing UI code
- Before shipping UI changes

## Common Layout Issues

### 1. Infinite Sizing

**Symptom**: View expands unexpectedly

```swift
// PROBLEM
List {
  Text("Item")
}
// List expands infinitely in ScrollView

// FIX
List {
  Text("Item")
}
.frame(height: 300)
```

### 2. Missing Alignment

**Symptom**: Items not aligned as expected

```swift
// PROBLEM
VStack {
  Text("Short")
  Text("Longer text here")
}
// Default center alignment

// FIX
VStack(alignment: .leading) {
  Text("Short")
  Text("Longer text here")
}
```

### 3. Spacer Battles

**Symptom**: Layout unpredictable with multiple Spacers

```swift
// PROBLEM
HStack {
  Spacer()
  Text("A")
  Spacer()
  Text("B")
  Spacer()
}
// Equal spacing may not be what you want

// FIX
HStack {
  Text("A")
  Spacer()
  Text("B")
}
```

### 4. GeometryReader Misuse

**Symptom**: Layout breaks or behaves oddly

```swift
// PROBLEM
GeometryReader { geo in
  Text("Hello")
    .frame(width: geo.size.width)
}
// GeometryReader proposes all available space

// FIX: Only use GeometryReader when truly needed
// Prefer native SwiftUI sizing
```

### 5. Z-Index Issues

**Symptom**: Overlays not appearing correctly

```swift
// PROBLEM
ZStack {
  Background()
  Content()
  Overlay()  // May be behind Content
}

// FIX
ZStack {
  Background()
  Content()
  Overlay()
}
.zIndex(1)  // Or use explicit ordering
```

## Layout Debugging

### Visual Debugging
```swift
view
  .border(Color.red)  // See bounds
  .background(Color.blue.opacity(0.3))  // See background
```

### Print Sizes
```swift
view
  .background(
    GeometryReader { geo in
      Color.clear.onAppear {
        print("Size: \(geo.size)")
      }
    }
  )
```

## Best Practices

### 1. Let SwiftUI Size Things
```swift
// Prefer
Text("Hello")
  .padding()

// Over
Text("Hello")
  .frame(width: 100, height: 50)
```

### 2. Use Appropriate Containers
```swift
// ScrollView for scrollable content
// List for dynamic lists
// LazyVStack for large lists
// VStack for small, fixed content
```

### 3. Consistent Spacing
```swift
VStack(spacing: 16) {  // Explicit spacing
  Item1()
  Item2()
}
```

### 4. Safe Area Handling
```swift
view
  .ignoresSafeArea(.keyboard)  // Specific
  // Not .ignoresSafeArea()  // Too broad
```

## Sanity Check List

- [ ] No infinite sizing issues
- [ ] Explicit alignment where needed
- [ ] Spacers used appropriately
- [ ] GeometryReader only when necessary
- [ ] Z-ordering correct
- [ ] Safe areas respected
- [ ] Consistent spacing
