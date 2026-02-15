# Sidebar Session List Redesign

## Overview

Redesigned the sidebar session list with clearer visual hierarchy, making it easier to distinguish repositories from their sessions at a glance.

## What Changed

### 1. Repository Section Headers (ModuleSectionHeader)

**Before:**
```
AgentHub                              5
──────────────────────────────────────
```
- Small, secondary-colored text
- Count on the right
- Not visually distinct

**After:**
```
╔══════════════════════════════════════╗
║ AgentHub  [5]                        ║
╚══════════════════════════════════════╝
```
- **Larger, bold text** (14pt bold)
- **Badge** for session count (rounded capsule with theme color)
- **Background tint** for visual separation
- Padding increased for prominence

#### Key Improvements:
- ✅ Font size: 14pt (up from ~12pt)
- ✅ Font weight: Bold (up from semibold)
- ✅ Text color: Primary (up from secondary)
- ✅ Count badge: Capsule with brand color background
- ✅ Subtle background tint for section headers
- ✅ Increased padding (12pt top, 8pt bottom)

### 2. Session Rows (SelectedSessionRow)

**Before:**
```
● Session-abc123 • Claude     ★
  branch • 5 msgs • 2m ago
```

**After:**
```
    ⊙ session-abc123         Claude
      󰘬 main • 5 msgs • 2m ago
```

#### Visual Hierarchy Improvements:

##### **A. Indentation**
- 20pt left indent from section header
- Creates clear parent-child relationship
- Sessions visually nested under repositories

##### **B. Status Indicators**
- **Larger dots** (10x10 px, up from 8x8)
- **Colored borders** with glow effect
- **Smart colors:**
  - 🟢 **Green** - Active/primary session
  - 🟠 **Orange** - Starting/pending
  - ⚪ **Gray** - Idle session
- More prominent visual feedback

##### **C. Typography**
- **Session name:** 13pt medium monospace
- **Branch & metadata:** 11pt monospace (smaller)
- **Provider badge:** 9pt compact badge
- **Monospace font** for all technical info
- Clear size differentiation

##### **D. Layout**
- Cleaner spacing between elements
- Provider badge moved to right side
- Metadata row uses consistent monospace
- Better visual balance

##### **E. Interactive Feedback**
- **Rounded corners** (6pt radius)
- **Subtle background** for primary session
- **Border highlight** for selected item
- Clear hover/selection states

### 3. Visual Hierarchy Summary

```
Repository Name (14pt bold primary)         [Badge]
├─ Session 1 (13pt medium mono)            Provider
│  └─ 󰘬 branch • metadata (11pt mono)
├─ Session 2 (13pt medium mono)            Provider
│  └─ 󰘬 branch • metadata (11pt mono)
└─ Session 3 (13pt medium mono)            Provider
   └─ 󰘬 branch • metadata (11pt mono)
```

### 4. Spacing & Layout

- **Section spacing:** 16px between sections (up from 12px)
- **Row spacing:** 6px between sessions
- **Section padding:** Horizontal 8px padding
- **Row indentation:** 20px from left edge
- **Status dot spacing:** 12px from content

## Design Details

### Color System

#### Status Dots:
```swift
Green (#00C851)    - Active/primary session
Orange (#FF8800)   - Starting/pending
Gray (40% opacity) - Idle session
```

#### Backgrounds:
```swift
Primary row:  Theme color at 8-12% opacity
Section:      Canvas color at 50% opacity
```

#### Typography:
```swift
Repo name:     14pt Bold, Primary color
Session name:  13pt Medium Monospace
Branch/meta:   11pt Regular Monospace
Provider:      9pt Semibold
Badges:        9-11pt Rounded
```

### Layout Measurements

```
ModuleSectionHeader:
├─ Padding top: 12pt
├─ Padding bottom: 8pt
├─ Padding horizontal: 8pt
└─ Font: 14pt bold

SelectedSessionRow:
├─ Indent: 20pt
├─ Status dot: 10x10pt + 2pt border
├─ Content gap: 12pt
├─ Row padding vertical: 10pt
├─ Row padding trailing: 12pt
└─ Corner radius: 6pt
```

## Code Changes

### Files Modified (1)
- ✅ `SelectedSessionsPanelView.swift`
  - ModuleSectionHeader redesign
  - SelectedSessionRow redesign
  - Section spacing updates
  - Both single and multi-provider views

### Key Components

#### **ModuleSectionHeader**
- Larger, bolder repository name
- Capsule badge for session count
- Theme-aware colors
- Background tint for visual separation

#### **SelectedSessionRow**
- 20pt left indentation
- Prominent status indicator dots
- Monospace fonts for technical info
- Rounded corners with subtle backgrounds
- Border highlight for selected state
- Smart color coding

## Visual Comparison

### Before:
```
Sessions (Small, flat list)
──────────────────────────
AgentHub                 5
● session-abc • 2m ago
● session-def • 5m ago

MyProject                3
● session-ghi • 1m ago
```

### After:
```
Sessions (Clear hierarchy)
══════════════════════════
╔ AgentHub [5] ═══════════╗
║                         ║
║   ⊙ session-abc  Claude ║
║     󰘬 main • 2m ago     ║
║                         ║
║   ⊙ session-def  Claude ║
║     󰘬 feat • 5m ago     ║
╚═════════════════════════╝

╔ MyProject [3] ══════════╗
║                         ║
║   ⊙ session-ghi  Claude ║
║     󰘬 dev • 1m ago      ║
╚═════════════════════════╝
```

## Benefits

### 1. **Improved Scannability**
- Repository names stand out immediately
- Clear visual grouping of sessions
- Easy to count sessions per repo

### 2. **Better Status Communication**
- Color-coded dots are more prominent
- Green = active, Orange = starting, Gray = idle
- Instant visual feedback

### 3. **Enhanced Readability**
- Monospace fonts for technical info
- Consistent sizing hierarchy
- Clear indentation shows relationships

### 4. **Professional Appearance**
- Modern badge design
- Subtle backgrounds and borders
- Polished, intentional look

### 5. **Theme Integration**
- Uses RuntimeTheme for brand colors
- Adapts to custom YAML themes
- Light/dark mode aware

## Testing Checklist

- [ ] Repository names are larger and bolder
- [ ] Session count badges appear with theme color
- [ ] Sessions are visibly indented
- [ ] Status dots show correct colors:
  - [ ] Green for primary/active
  - [ ] Orange for starting
  - [ ] Gray for idle
- [ ] Branch names use monospace font
- [ ] Git branch icon appears correctly
- [ ] Metadata (msgs, time) uses monospace
- [ ] Provider badges are compact
- [ ] Section spacing is comfortable
- [ ] Selection highlighting works
- [ ] Theme colors apply correctly
- [ ] Light/dark mode both look good

## Future Enhancements

Potential improvements (not implemented):

1. **Collapsible Sections**
   - Click repo header to collapse/expand
   - Remember collapsed state per repo

2. **Drag & Drop Reordering**
   - Reorder sessions within repos
   - Move sessions between repos

3. **Context Menus**
   - Right-click for quick actions
   - Rename, delete, duplicate sessions

4. **Keyboard Navigation**
   - Arrow keys to navigate
   - Enter to select session

5. **Search/Filter**
   - Filter sessions by name
   - Search across all repos

6. **Activity Timeline**
   - Visual timeline of recent activity
   - Session duration bars

## Design Philosophy

The redesign follows these principles:

✨ **Clear Hierarchy** - Size and weight create obvious structure
✨ **Visual Consistency** - Monospace for code, rounded for UI
✨ **Color with Purpose** - Status colors communicate meaning
✨ **Intentional Spacing** - Whitespace creates relationships
✨ **Professional Polish** - Badges, borders, and backgrounds
✨ **Theme Respect** - Integrates with custom themes

The sidebar now feels like a proper **navigation tree** rather than a flat list, making it easier to find and manage sessions across multiple repositories.
