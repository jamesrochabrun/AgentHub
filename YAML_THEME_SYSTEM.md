# YAML Theme System

## Overview

AgentHub now supports custom YAML-based color themes alongside the built-in themes (Claude, Codex, Bat, Xcode, Custom). Users can create, share, and hot-reload custom themes by placing `.yaml` files in the themes directory.

## Features

✅ **Simple YAML Schema** - Easy-to-understand color definitions
✅ **Hot Reload** - Changes automatically apply when you save the file
✅ **Theme Discovery** - Automatically finds themes in the themes folder
✅ **Import/Export** - Import themes via file picker
✅ **Backward Compatible** - Existing built-in themes work unchanged

## Quick Start

### 1. Create a Theme

Create a `.yaml` file with your theme definition:

```yaml
name: "My Custom Theme"
version: "1.0"
author: "Your Name"
description: "A beautiful custom theme"

colors:
  brand:
    primary: "#9333EA"
    secondary: "#D946EF"
    tertiary: "#C4B5FD"
```

### 2. Place in Themes Folder

Save your theme to: `~/Library/Application Support/AgentHub/Themes/my-theme.yaml`

Or use the **"Import Theme..."** button in Settings.

### 3. Select Your Theme

Open **Settings** and select your theme from the Theme picker.

## Theme Schema

### Required Fields

```yaml
name: "Theme Name"  # Required: Display name

colors:
  brand:           # Required: Brand colors
    primary: "#RRGGBB"
    secondary: "#RRGGBB"
    tertiary: "#RRGGBB"
```

### Optional Fields

```yaml
version: "1.0"                    # Recommended for versioning
author: "Your Name"               # Your name or organization
description: "Theme description"  # What makes this theme special

colors:
  # Optional: Custom background colors
  backgrounds:
    dark: "#262624"
    light: "#FAF9F5"
    expandedContentDark: "#1F2421"
    expandedContentLight: "#FFFFFF"

  # Optional: Custom gradient overlay
  backgroundGradient:
    - color: "#9333EA"
      opacity: 0.08
    - color: "#D946EF"
      opacity: 0.04
    - color: "#000000"
      opacity: 0.0
```

## Color Format

All colors must be in hex format:
- ✅ `#RRGGBB` (e.g., `#9333EA`)
- ✅ `RRGGBB` (e.g., `9333EA`)
- ❌ RGB values, color names, or HSL not supported

## Hot Reload

When a YAML theme is active:
1. Edit your `.yaml` file
2. Save the changes
3. Theme updates automatically in the app - no restart needed!

You'll see "✨ Theme changes are automatically reloaded" in Settings when using a YAML theme.

## Example Themes

### Minimal Theme (Required Fields Only)

```yaml
name: "Simple Blue"

colors:
  brand:
    primary: "#3B82F6"
    secondary: "#60A5FA"
    tertiary: "#93C5FD"
```

### Complete Theme (All Features)

```yaml
name: "Midnight Aurora"
version: "1.0"
author: "AgentHub Team"
description: "A beautiful dark theme with aurora-inspired colors"

colors:
  brand:
    primary: "#9333EA"
    secondary: "#D946EF"
    tertiary: "#C4B5FD"

  backgrounds:
    dark: "#262624"
    light: "#FAF9F5"
    expandedContentDark: "#1F2421"
    expandedContentLight: "#FFFFFF"

  backgroundGradient:
    - color: "#9333EA"
      opacity: 0.08
    - color: "#D946EF"
      opacity: 0.04
    - color: "#000000"
      opacity: 0.0
```

## Settings UI

The Settings panel now includes:

- **Theme Picker** - Select from built-in and YAML themes
- **Import Theme...** - Import a `.yaml` file from anywhere
- **Open Themes Folder** - Quick access to themes directory
- **Refresh Button** - Re-scan themes folder for new files
- **Hot Reload Indicator** - Shows when theme auto-updates are active

## Implementation Details

### Architecture

- **Parallel System** - YAML themes work alongside built-in themes
- **Theme Manager** - Centralized service for discovery, loading, and caching
- **File Watcher** - Monitors theme files for changes
- **Environment Injection** - Themes available via SwiftUI environment

### File Structure

```
app/modules/AgentHubCore/Sources/AgentHub/Design/Theme/
├── Models/
│   ├── YAMLTheme.swift           # YAML schema definition
│   └── RuntimeTheme.swift        # Runtime theme with resolved colors
├── Parsing/
│   └── YAMLThemeParser.swift     # Parser and validator
├── Management/
│   ├── ThemeManager.swift        # Theme discovery, loading, caching
│   └── ThemeFileWatcher.swift    # Hot-reload file watching
└── Environment/
    └── ThemeEnvironment.swift    # SwiftUI environment integration
```

### Usage in Code

Views can access the current theme via environment:

```swift
struct MyView: View {
  @Environment(\.runtimeTheme) private var theme

  var body: some View {
    Text("Hello")
      .foregroundColor(Color.brandPrimary(from: theme))
      .background(Color.brandSecondary(from: theme))
  }
}
```

For backward compatibility, views without the theme parameter still work:

```swift
Text("Hello")
  .foregroundColor(Color.brandPrimary)  // Uses UserDefaults theme
```

## Troubleshooting

### Theme Not Appearing

1. Check file extension is `.yaml` or `.yml`
2. Verify file is in `~/Library/Application Support/AgentHub/Themes/`
3. Click the refresh button in Settings
4. Check console for validation errors

### Theme Not Loading

1. Verify YAML syntax is valid
2. Ensure required fields are present (`name`, `colors.brand.*`)
3. Check color format is hex (`#RRGGBB`)
4. Look for error messages in Console.app

### Hot Reload Not Working

1. Ensure theme is loaded (selected in Settings)
2. Save the file after making changes
3. Check file permissions (file must be writable)

## Future Enhancements

Potential additions (not currently implemented):

- Theme marketplace/sharing
- Visual theme editor UI
- Export current theme to YAML
- Theme inheritance (base + overrides)
- Full design token theming (spacing, fonts, etc.)
- Per-provider color overrides

## Testing

### Manual Testing

1. **Create test theme**: See `example-theme.yaml` in repo
2. **Import via Settings**: Use "Import Theme..." button
3. **Switch themes**: Verify colors update throughout app
4. **Test hot reload**: Edit theme file, save, verify auto-update
5. **Restart app**: Verify theme persists across sessions
6. **Test validation**: Try invalid YAML, verify helpful errors

### Unit Tests

Tests are located in `app/modules/AgentHubCore/Tests/AgentHubTests/Theme/`:

- `YAMLThemeParserTests` - Parsing and validation
- `ThemeManagerTests` - Discovery, loading, caching

## Dependencies

- **Yams 5.0+** - YAML parsing library

## License

This theme system is part of AgentHub and follows the same license as the main project.
