# SwiftUI Accessibility Audit

Audit checklist for ensuring SwiftUI views are accessible.

## When to Use

- After creating new UI components
- During ui-polish review
- Before shipping UI changes

## Audit Checklist

### 1. VoiceOver Labels
- [ ] All interactive elements have accessibility labels
- [ ] Labels are descriptive and meaningful
- [ ] Custom views include `.accessibilityLabel()`

```swift
Button(action: { }) {
  Image(systemName: "plus")
}
.accessibilityLabel("Add new item")
```

### 2. Accessibility Traits
- [ ] Buttons have `.isButton` trait
- [ ] Headers have `.isHeader` trait
- [ ] Images are marked decorative if appropriate

```swift
Image(systemName: "star.fill")
  .accessibilityHidden(true)  // Decorative
```

### 3. Dynamic Type Support
- [ ] Text uses system fonts or scaled custom fonts
- [ ] Layout adapts to larger text sizes
- [ ] No truncation at accessibility sizes

```swift
Text("Hello")
  .font(.body)  // Automatically scales
```

### 4. Color Contrast
- [ ] Text meets WCAG AA contrast ratio (4.5:1)
- [ ] Interactive elements are clearly visible
- [ ] Don't rely on color alone for meaning

### 5. Touch Targets
- [ ] Interactive elements are at least 44x44pt
- [ ] Adequate spacing between targets

```swift
Button("Action") { }
  .frame(minWidth: 44, minHeight: 44)
```

### 6. Focus Order
- [ ] Logical reading order
- [ ] Related items grouped
- [ ] No confusing navigation

```swift
VStack {
  // Items in logical order
}
.accessibilityElement(children: .contain)
```

## Common Issues

### Missing Labels
```swift
// BAD
Button(action: { }) {
  Image(systemName: "trash")
}

// GOOD
Button(action: { }) {
  Image(systemName: "trash")
}
.accessibilityLabel("Delete")
```

### Non-Scaling Text
```swift
// BAD
Text("Hello")
  .font(.system(size: 14))

// GOOD
Text("Hello")
  .font(.subheadline)
```

### Small Touch Targets
```swift
// BAD
Button("X") { }
  .frame(width: 20, height: 20)

// GOOD
Button("X") { }
  .frame(minWidth: 44, minHeight: 44)
```

## Audit Report Format

```markdown
## Accessibility Audit: <Component>

### VoiceOver
- [ ] Labels present
- Issues: <list>

### Dynamic Type
- [ ] Scales correctly
- Issues: <list>

### Contrast
- [ ] Meets WCAG AA
- Issues: <list>

### Touch Targets
- [ ] ≥44pt
- Issues: <list>

**Verdict: PASS / FAIL**
```
