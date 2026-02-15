# New Session UI Redesign

## Overview

Redesigned the "Start Session" area at the top of the sidebar with a command palette approach inspired by VS Code's Cmd+K interface. Replaced the collapsible form with a prominent button that opens a modal for a cleaner, more intentional user experience.

## What Changed

### Before: Collapsible Form
```
┌────────────────────────────────┐
│ Start Session            [+]   │ ← Click to expand
├────────────────────────────────┤
│ [Expanded form with all fields]│
│ - Repository picker            │
│ - Prompt text area             │
│ - Provider pills               │
│ - Mode toggles                 │
│ - Launch button                │
└────────────────────────────────┘
```

### After: Command Palette Button
```
┌────────────────────────────────┐
│ ⊕ New Session          ⌘N     │ ← Prominent button
│   Start Claude or Codex        │
└────────────────────────────────┘
        ↓ Click opens modal
┌─────────────────────────────────────┐
│ ⊕  New Session              ✕      │
│    Configure and launch...          │
├─────────────────────────────────────┤
│ [Organized modal with sections]     │
│ • Repository selection              │
│ • Prompt input                      │
│ • Mode selection                    │
│ • Provider configuration            │
│ • Launch actions                    │
└─────────────────────────────────────┘
```

## New Components

### 1. NewSessionButton.swift

**Purpose:** Prominent action button at the top of sidebar

**Design Features:**
- ✨ **Gradient background** with brand colors
- ✨ **Icon + label**: "New Session" with "Start Claude or Codex" subtitle
- ✨ **Keyboard shortcut hint**: Shows "⌘N" badge
- ✨ **Drop shadow** for elevation
- ✨ **Theme-aware** colors from RuntimeTheme
- ✨ **Keyboard shortcut**: Cmd+N triggers the button

**Visual Design:**
```
┌─────────────────────────────────┐
│ ⊕  New Session         [⌘N]    │
│    Start Claude or Codex        │
└─────────────────────────────────┘
  ↑                        ↑
  Icon + text          Shortcut badge
```

**Key Properties:**
- Button height: 44px (iOS-standard touch target)
- Border radius: 10px (rounded, modern)
- Shadow: 8px blur, 4px offset
- Gradient: Brand primary → 85% opacity
- White text with subtle overlay border

### 2. NewSessionCommandPalette.swift

**Purpose:** Modal dialog for session configuration

**Design Features:**
- ✨ **Fixed size**: 550x650 optimal window
- ✨ **Sectioned layout** with clear visual hierarchy
- ✨ **Icons for sections**: Visual wayfinding
- ✨ **Keyboard shortcuts**: Esc to close, Enter to launch
- ✨ **Smart defaults**: Empty states and placeholders
- ✨ **Progress feedback**: Live progress for worktree creation
- ✨ **Error handling**: Inline error messages

**Sections:**

#### **Header**
- Large "New Session" title
- Descriptive subtitle
- Close button (X icon)
- Branded circular icon

#### **Repository Section**
- Large dropdown-style button for repo selection
- Path display below selection
- Paperclip button for file attachments
- Attached files chips (removable)

#### **Prompt Section**
- Multi-line text editor (100px height)
- Smart placeholder based on mode
- Labeled as optional for manual mode
- Required for smart mode

#### **Mode Section** (if smart mode available)
- Manual vs Smart toggle buttons
- Beta badge for Smart mode
- Icon indicators

#### **Work Mode Section** (Manual mode only)
- Local branch vs New worktree
- Branch picker for worktree mode
- Base branch selection

#### **Provider Section**
- Checkbox-style toggles
- Claude (with dangerous mode indication)
- Codex
- Visual checkmarks when selected
- Large tap targets (44px height)

#### **Progress Section** (if creating worktrees)
- Per-provider progress bars
- Status messages
- Percentage indicators
- Success/failure icons

#### **Footer**
- Reset button (left)
- Cancel button (left of primary)
- Launch button (right, prominent)
- Keyboard shortcuts work

## Visual Design System

### Colors
```swift
Primary CTA:     Brand gradient (theme-aware)
Section headers: Brand primary with icons
Backgrounds:     Adaptive (dark: 0.12, light: white)
Borders:         Subtle borders (1-1.5px)
Errors:          Orange with 10% background tint
Success:         Green indicators
```

### Typography
```swift
Modal title:      18pt bold
Section headers:  13pt semibold
Body text:        13pt regular
Helper text:      11-12pt
Placeholder:      13pt secondary opacity 0.6
```

### Spacing
```swift
Modal padding:    24px
Section spacing:  20px
Element spacing:  12px
Button height:    44px (touch target)
Corner radius:    8-10px
```

### Interactive Elements
```swift
Buttons:          RoundedRectangle(8-10px)
Inputs:           RoundedRectangle(8px)
Pills/chips:      Capsule()
Borders:          1-1.5px strokeBorder
States:           Selected = fill + border highlight
```

## User Experience Improvements

### **1. Clearer Intent**
- Button explicitly says "New Session"
- No ambiguity about what it does
- Keyboard shortcut visible upfront

### **2. Less Visual Clutter**
- Sidebar stays clean and compact
- Form doesn't expand inline
- Focus stays on session list

### **3. Modal Focus**
- Full attention on configuration
- Larger interaction targets
- Better organization of options

### **4. Keyboard-Friendly**
- Cmd+N to open
- Esc to close
- Enter to launch
- Tab navigation works

### **5. Progressive Disclosure**
- Only show relevant options
- Worktree options appear when needed
- Progress appears during creation
- Errors show inline, not as alerts

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘N` | Open New Session palette |
| `Esc` | Close palette |
| `⌘↵` | Launch session (primary action) |
| `Tab` | Navigate between fields |

## Integration Points

### MultiProviderSessionsListView.swift
**Changed:** Line 196-202
- Replaced `MultiSessionLaunchView` with `NewSessionButton`
- Padding adjusted to 12px bottom
- Same viewModel and intelligenceViewModel passed through

### Original vs New
```swift
// Before
MultiSessionLaunchView(
  viewModel: multiLaunchViewModel,
  intelligenceViewModel: intelligenceViewModel
)

// After
NewSessionButton(
  viewModel: multiLaunchViewModel,
  intelligenceViewModel: intelligenceViewModel
)
```

## File Changes

### New Files (2)
1. ✅ `NewSessionButton.swift` (130 lines)
   - Prominent button trigger
   - Theme-aware styling
   - Keyboard shortcut

2. ✅ `NewSessionCommandPalette.swift` (550+ lines)
   - Modal command palette
   - Sectioned configuration UI
   - Smart defaults and validation

### Modified Files (1)
1. ✅ `MultiProviderSessionsListView.swift`
   - Swapped component (1 line change)
   - Uses new button instead of collapsible form

### Preserved Files (1)
- ✅ `MultiSessionLaunchView.swift` (unchanged)
  - Still exists for backward compatibility
  - Can be deprecated later
  - ViewModel logic unchanged

## Testing Checklist

- [ ] Button appears at top of sidebar
- [ ] Button shows gradient with theme colors
- [ ] Keyboard shortcut badge visible (⌘N)
- [ ] Cmd+N opens the palette
- [ ] Modal opens centered and sized correctly
- [ ] Repository picker works
- [ ] File attachment works (drop + picker)
- [ ] Prompt input accepts multi-line text
- [ ] Mode toggle works (Manual/Smart)
- [ ] Work mode toggle works (Local/Worktree)
- [ ] Branch picker loads branches
- [ ] Provider toggles work (Claude/Codex)
- [ ] Launch button enables when valid
- [ ] Progress shows during worktree creation
- [ ] Errors display inline
- [ ] Esc closes the modal
- [ ] Enter launches session
- [ ] Modal auto-closes on successful launch
- [ ] Theme colors apply correctly
- [ ] Light/dark mode both look good

## Design Inspiration

### VS Code Command Palette
✅ Keyboard shortcut to open (Cmd+K → Cmd+P)
✅ Modal overlay with focus
✅ Esc to close
✅ Enter to execute

### macOS Spotlight
✅ Clean, minimal interface
✅ Prominent at top of UI
✅ Quick access via keyboard

### Slack Quick Switcher
✅ Single entry point
✅ Progressive disclosure
✅ Smart defaults

## Benefits

### **1. Discoverability**
- Button is always visible
- Clear call-to-action
- Keyboard shortcut shown

### **2. Efficiency**
- One click/shortcut to open
- Larger targets in modal
- Faster to navigate

### **3. Organization**
- Logical section grouping
- Clear visual hierarchy
- Less overwhelming

### **4. Professionalism**
- Modern modal design
- Polished interactions
- Consistent with platform conventions

### **5. Flexibility**
- Easy to add new options
- Sections can expand/collapse in future
- Modal can grow as needed

## Future Enhancements

Potential improvements (not implemented):

1. **Recent Configurations**
   - Show last 3 used configurations
   - Quick-launch buttons for common setups
   - Save custom configurations

2. **Templates**
   - Pre-configured session templates
   - "New Feature Branch" template
   - "Bug Fix" template with smart mode

3. **Quick Actions**
   - Cmd+Shift+N for "New worktree from current"
   - Cmd+Opt+N for "Launch in local"
   - Context-aware defaults

4. **Search & Filtering**
   - Search repositories
   - Filter by recent activity
   - Smart suggestions based on current context

5. **Multi-Step Wizard**
   - Step 1: Choose repository
   - Step 2: Configure session
   - Step 3: Review and launch
   - Progress indicator

6. **Session Presets**
   - Save configuration as preset
   - Name and reuse presets
   - Share presets with team

## Migration Notes

### For Users
- Old collapsible form still works if needed
- New button is drop-in replacement
- No breaking changes to functionality
- Keyboard shortcut (Cmd+N) is new

### For Developers
- `MultiSessionLaunchViewModel` unchanged
- All logic preserved
- UI layer only changed
- Can keep both UIs if desired

## Design Philosophy

The redesign follows these principles:

✨ **Intentional Actions** - Button makes intent explicit
✨ **Focus** - Modal provides dedicated configuration space
✨ **Efficiency** - Keyboard shortcuts for power users
✨ **Clarity** - Sections organize related options
✨ **Feedback** - Progress and errors inline
✨ **Flexibility** - Modal can grow with features

The new design transforms session creation from an **inline form** to a **focused workflow**, making it feel more intentional and professional while improving usability and discoverability.
