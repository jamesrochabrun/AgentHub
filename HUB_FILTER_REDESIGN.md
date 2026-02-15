# Hub Filter & Session Context Redesign

## Overview

Redesigned the Hub view's provider filtering system by moving it from the main content area to the sidebar, and replaced the main content header with context-rich session information. This change brings filtering closer to the session list and gives the main panel a more purposeful header showing details about the selected session.

## What Changed

### Before: Provider Filter in Main Content Header

```
┌─────────────────────────────────────────────┐
│ Main Content Area                           │
├─────────────────────────────────────────────┤
│ Hub    [All] [Claude] [Codex]    [□][☰][⊞] │ ← Filter tabs here
├─────────────────────────────────────────────┤
│                                             │
│   Session content...                        │
│                                             │
└─────────────────────────────────────────────┘
```

### After: Filter in Sidebar + Session Context Header

```
┌──────────────────┬───────────────────────────┐
│ Sidebar          │ Main Content Area         │
├──────────────────┼───────────────────────────┤
│ ⊕ New Session    │ ● Claude  AgentHub        │
│                  │   ⎇ main • 15m • 45K tok  │ ← Session context
│ [All][Claude]... │ [□][☰][⊞]                 │
│                  ├───────────────────────────┤
│ Focused Sessions │                           │
│ • session-abc    │   Session content...      │
│ • session-def    │                           │
└──────────────────┴───────────────────────────┘
   ↑ Filter here
```

## Design Rationale

### 1. **Filter Near the List**
- Users browse sessions in the sidebar, so filtering should be right there
- No need to look elsewhere to change what sessions are visible
- More intuitive workflow: "I want to see Claude sessions" → filter right above the list

### 2. **Context-Rich Main Header**
- Main panel shows details about the active session instead of redundant "Hub" title
- At-a-glance visibility of:
  - **Provider** (Claude/Codex) with colored indicator
  - **Repository name**
  - **Git branch** with icon
  - **Session duration** (how long it's been active)
  - **Token usage** (cumulative input + output tokens)

### 3. **Better Use of Space**
- Sidebar filter is more compact (chips instead of tabs)
- Main header provides useful context instead of just navigation
- Layout mode toggles stay in main header where they belong (they control main content layout)

## Implementation Details

### 1. Moved HubFilterMode Enum

**File:** `MultiProviderMonitoringPanelView.swift` (lines 69-83)

Changed from `private enum` to package-level `enum` so it can be shared between files:

```swift
enum HubFilterMode: Int, CaseIterable {
  case all = 0
  case claude = 1
  case codex = 2

  var displayName: String {
    switch self {
    case .all: return "All"
    case .claude: return "Claude"
    case .codex: return "Codex"
    }
  }
}
```

### 2. Created ProviderFilterControl (Sidebar)

**File:** `MultiProviderSessionsListView.swift`

New component that renders filter chips in the sidebar:

```swift
private struct ProviderFilterControl: View {
  @Binding var filterMode: HubFilterMode
  let claudeCount: Int
  let codexCount: Int
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 8) {
      ForEach(HubFilterMode.allCases, id: \.self) { mode in
        filterChip(for: mode)
      }
    }
  }

  private func filterChip(for mode: HubFilterMode) -> some View {
    // Renders pill-shaped button with:
    // - Mode name (All/Claude/Codex)
    // - Session count badge
    // - Selected state styling with theme colors
  }
}
```

**Design Features:**
- **Pill-shaped chips** instead of tabs with underlines
- **Count badges** inside each chip (rounded capsule background)
- **Selected state**: Theme primary color background, white text
- **Unselected state**: Surface overlay background, primary text
- **Animated transitions** (0.2s ease-in-out)

### 3. Created SessionContextHeader (Main Content)

**File:** `MultiProviderMonitoringPanelView.swift`

New component that shows rich session context:

```swift
private struct SessionContextHeader: View {
  let item: ProviderMonitoringItem
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 12) {
      // Provider badge (colored dot + name)
      // Repository name (bold monospace)
      // Branch name (git icon + monospace)
      // Duration (clock icon + formatted time)
      // Token count (doc icon + formatted count)
    }
  }
}
```

**Information Displayed:**

| Element | Icon | Format | Example |
|---------|------|--------|---------|
| Provider | `●` (colored dot) | Badge with name | `● Claude` |
| Repository | - | Bold monospace | `AgentHub` |
| Branch | `arrow.branch` | Monospace | `⎇ main` |
| Duration | `clock` | Formatted time | `15m` or `2h 30m` |
| Tokens | `doc.text` | Formatted count | `45K tokens` |

**Duration Formatting:**
- Under 60s: `"30s"`
- Under 60m: `"15m"`
- Over 60m: `"2h 30m"`

**Token Display:**
- Uses `state.totalTokens` (inputTokens + outputTokens)
- Only shown for monitored sessions (not pending)
- Helps track context window usage at a glance

### 4. Updated MultiProviderMonitoringPanelView

**Changes:**
1. **Accepts filterMode as Binding** (from parent):
   ```swift
   @Binding var filterMode: HubFilterMode

   public init(
     claudeViewModel: CLISessionsViewModel,
     codexViewModel: CLISessionsViewModel,
     primarySessionId: Binding<String?>,
     filterMode: Binding<HubFilterMode>  // Added
   )
   ```

2. **Removed HubFilterControl component** (no longer needed)

3. **Updated header**:
   ```swift
   private var header: some View {
     HStack(spacing: 12) {
       // Show session context in single mode, "Hub" in list/grid mode
       if layoutMode == .single, let item = visibleItems.first {
         SessionContextHeader(item: item)
       } else {
         Text("Hub")
       }

       Spacer()

       // Layout mode toggles (unchanged)
       // ...
     }
   }
   ```

### 5. Updated MultiProviderSessionsListView

**Changes:**
1. **Added filterMode state**:
   ```swift
   @State private var hubFilterMode: HubFilterMode = .all
   ```

2. **Added filter control to sidebar**:
   ```swift
   private var sessionListContent: some View {
     VStack(spacing: 0) {
       // 1. New Session Button
       NewSessionButton(...)

       // 2. Provider Filter ← NEW
       ProviderFilterControl(
         filterMode: $hubFilterMode,
         claudeCount: claudeViewModel.monitoredSessions.count +
                      claudeViewModel.pendingHubSessions.count,
         codexCount: codexViewModel.monitoredSessions.count +
                     codexViewModel.pendingHubSessions.count
       )
       .padding(.bottom, 16)

       // 3. Focused Sessions
       // 4. Browse Sessions
     }
   }
   ```

3. **Passed filterMode to detail view**:
   ```swift
   MultiProviderMonitoringPanelView(
     claudeViewModel: claudeViewModel,
     codexViewModel: codexViewModel,
     primarySessionId: $primarySessionId,
     filterMode: $hubFilterMode  // Added
   )
   ```

## Visual Design

### Provider Filter Chips (Sidebar)

```
┌─────────────────────────────────────────┐
│ [  All  5 ] [ Claude  3 ] [ Codex  2 ]  │
│     ↑           ↑             ↑         │
│  Selected   Unselected   Unselected     │
└─────────────────────────────────────────┘
```

**Styling:**
- **Chip padding:** 12px horizontal, 8px vertical
- **Badge:** Capsule background, 5px horizontal padding
- **Corner radius:** 8px
- **Border:** 1px, theme color when selected
- **Background:** Theme primary when selected, surface overlay otherwise
- **Text:** White when selected, primary otherwise
- **Animation:** 0.2s ease-in-out on selection change

### Session Context Header (Main Content)

```
┌──────────────────────────────────────────────────────────────┐
│ ● Claude  AgentHub  ⎇ main  🕐 15m  📄 45K tokens  [□][☰][⊞] │
│   ↑        ↑         ↑        ↑        ↑                      │
│ Provider  Repo     Branch   Duration  Tokens                  │
└──────────────────────────────────────────────────────────────┘
```

**Element Spacing:** 12px between each piece of information

**Provider Badge:**
- 6x6 colored dot (theme color for provider)
- 11pt semibold rounded font
- Capsule background with 12% opacity of theme color
- 8px horizontal, 4px vertical padding

**Typography:**
- Repository: 13pt bold monospace
- Branch: 12pt monospace, secondary color
- Duration: 12pt monospace, secondary color
- Tokens: 12pt monospace, secondary color

**Icons:**
- Branch: `arrow.branch` (10pt)
- Duration: `clock` (10pt)
- Tokens: `doc.text` (10pt)

## Benefits

### 1. **Improved Workflow**
- Filter is directly adjacent to the session list
- No context switching between sidebar and main content to change filter
- Clear cause-and-effect: filter changes → list updates immediately

### 2. **Better Information Density**
- Main header now provides useful context instead of just "Hub" label
- At-a-glance visibility of session details without clicking anything
- Token usage visible for tracking context window consumption

### 3. **Cleaner Layout**
- Sidebar has all session browsing controls (filter + list)
- Main content focuses on session interaction
- Layout mode toggles stay where they belong (controlling main content)

### 4. **Consistent with Design Patterns**
- Filters near filtered content (common pattern: Gmail, Slack, etc.)
- Context headers showing details about selected item (VS Code, Xcode)
- Progressive disclosure (only show session context when one session is focused)

### 5. **Scalability**
- Easy to add more filter options (Smart mode, Dangerous mode, etc.)
- Session context can expand to show more metrics (cost, message count)
- Chip design works well with many filter options

## Layout Modes

### Single Mode (layoutMode == .single)
- **Main Header:** Shows `SessionContextHeader` for the focused session
- **Filter:** Active in sidebar, filters which session is shown in single view
- **Behavior:** User filters to desired provider, sees their sessions, focuses one

### List/Grid Mode (layoutMode != .single)
- **Main Header:** Shows "Hub" title (no specific session is focused)
- **Filter:** Active in sidebar, filters visible sessions in the grid
- **Behavior:** User filters by provider, sees all matching sessions in grid

## Session Context Details

### Repository Name
- Extracted from `item.projectPath` using `URL.lastPathComponent`
- Example: `/Users/user/repos/AgentHub` → `"AgentHub"`
- Bold monospace for clarity

### Branch Name
- For pending: `pending.worktree.branch`
- For monitored: `session.branchName`
- Only shown if available (some sessions may not have branch info)

### Duration
- Calculated as `Date().timeIntervalSince(item.timestamp)`
- Formatted as:
  - `< 60s`: `"30s"`
  - `< 3600s`: `"15m"`
  - `>= 3600s`: `"2h 30m"`
- Gives sense of how long session has been active

### Token Count
- Uses `state.totalTokens` (inputTokens + outputTokens)
- Only shown for monitored sessions with state
- Formatted as: `"45K tokens"` or `"2M tokens"` using formatTokenCount
- Helps users track context window usage (200K limit)

## Testing Checklist

- [ ] Filter chips appear in sidebar above "Focused Sessions"
- [ ] Clicking All/Claude/Codex filters sessions correctly
- [ ] Selected chip has theme color background and white text
- [ ] Unselected chips have surface overlay background
- [ ] Session count badges show correct numbers
- [ ] Main header shows session context in single mode
- [ ] Main header shows "Hub" title in list/grid mode
- [ ] Provider badge shows correct color (Claude/Codex theme)
- [ ] Repository name displays correctly
- [ ] Branch name appears with git icon (when available)
- [ ] Duration updates and formats correctly
- [ ] Token count appears for monitored sessions
- [ ] Token count hidden for pending sessions
- [ ] Layout mode toggles still work
- [ ] Filter state persists when switching layout modes
- [ ] Theme colors apply to both filter chips and provider badge
- [ ] Animations work smoothly (0.2s transitions)

## Future Enhancements

Potential improvements (not implemented):

1. **Additional Filter Options**
   - Smart mode sessions
   - Dangerous mode sessions
   - By status (active, idle, waiting)
   - By repository

2. **Session Context Expansion**
   - Message count
   - Cost estimate (based on token usage)
   - Model name
   - Last activity timestamp

3. **Filter Persistence**
   - Remember filter selection across app restarts
   - Per-repository default filters

4. **Search Integration**
   - Quick filter by typing
   - Fuzzy search across session names

5. **Advanced Metrics**
   - Average response time
   - Tool usage statistics
   - Cache hit rate

## Design Philosophy

The redesign follows these principles:

✨ **Proximity** - Related controls grouped together (filter near list)
✨ **Context** - Show relevant information where it's needed (session details in main view)
✨ **Clarity** - Clear visual hierarchy and information structure
✨ **Efficiency** - Reduce clicks and eye movement
✨ **Consistency** - Follow established UI patterns and conventions
✨ **Scalability** - Design can grow to accommodate new features

This change transforms the Hub view from a navigation-focused interface to a context-rich workspace, making it easier for users to filter sessions and understand what they're working on at a glance.
