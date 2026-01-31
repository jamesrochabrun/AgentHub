//
//  HighlightCodeSyntaxHighlighter.swift
//  AgentHub
//
//  Created by Assistant on 1/30/26.
//

import HighlightSwift
import MarkdownUI
import SwiftUI

// MARK: - HighlightCodeSyntaxHighlighter

/// A syntax highlighter for MarkdownUI that uses HighlightSwift for multi-language support.
///
/// Supports 50+ languages with automatic detection and theme-aware coloring.
struct HighlightCodeSyntaxHighlighter: CodeSyntaxHighlighter {
  private let colorScheme: ColorScheme

  init(colorScheme: ColorScheme) {
    self.colorScheme = colorScheme
  }

  func highlightCode(_ code: String, language: String?) -> Text {
    // HighlightSwift's attributedText is async, but CodeSyntaxHighlighter expects sync
    // Use a blocking approach with a semaphore
    let semaphore = DispatchSemaphore(value: 0)
    var result: Text = Text(code)

    let highlight = Highlight()
    let highlightLang = mapLanguage(language)
    let colors: HighlightColors = colorScheme == .dark ? .dark(.github) : .light(.github)

    Task.detached(priority: .high) {
      do {
        let attributed: AttributedString
        if let lang = highlightLang {
          attributed = try await highlight.attributedText(code, language: lang, colors: colors)
        } else {
          attributed = try await highlight.attributedText(code, colors: colors)
        }
        result = attributedStringToText(attributed)
      } catch {
        // Fallback to plain text on error
        result = Text(code)
      }
      semaphore.signal()
    }

    // Wait with timeout to avoid blocking forever
    _ = semaphore.wait(timeout: .now() + 2.0)
    return result
  }

  // MARK: - Private Helpers

  /// Maps markdown language hints to HighlightSwift HighlightLanguage enum
  private func mapLanguage(_ language: String?) -> HighlightLanguage? {
    guard let lang = language?.lowercased() else { return nil }

    switch lang {
    case "swift": return .swift
    case "python", "py": return .python
    case "javascript", "js": return .javaScript
    case "typescript", "ts": return .typeScript
    case "bash", "sh", "shell", "zsh": return .bash
    case "json": return .json
    case "yaml", "yml": return .yaml
    case "html": return .html
    case "xml": return .html
    case "css": return .css
    case "sql": return .sql
    case "ruby", "rb": return .ruby
    case "go", "golang": return .go
    case "rust", "rs": return .rust
    case "java": return .java
    case "kotlin", "kt": return .kotlin
    case "c": return .c
    case "cpp", "c++", "cxx": return .cPlusPlus
    case "csharp", "c#", "cs": return .cSharp
    case "php": return .php
    case "markdown", "md": return .markdown
    case "diff": return .diff
    case "dockerfile", "docker": return .dockerfile
    case "makefile", "make": return .makefile
    case "graphql", "gql": return .graphQL
    case "r": return .r
    case "scala": return .scala
    case "lua": return .lua
    case "perl": return .perl
    case "haskell", "hs": return .haskell
    case "elixir", "ex": return .elixir
    case "erlang", "erl": return .erlang
    case "clojure", "clj": return .clojure
    case "objc", "objective-c", "objectivec": return .objectiveC
    case "dart": return .dart
    case "julia": return .julia
    case "toml": return .toml
    case "scss": return .scss
    case "less": return .less
    case "latex", "tex": return .latex
    default: return nil
    }
  }
}

// MARK: - AttributedString to Text Conversion

/// Converts an AttributedString to SwiftUI Text with proper styling
private func attributedStringToText(_ attributedString: AttributedString) -> Text {
  var result = Text("")

  for run in attributedString.runs {
    let string = String(attributedString[run.range].characters)
    var text = Text(string)

    // Apply foreground color from the attributed string
    #if canImport(AppKit)
    if let foregroundColor = run[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self] {
      text = text.foregroundColor(Color(foregroundColor))
    }
    #endif

    result = result + text
  }

  return result
}

// MARK: - CodeSyntaxHighlighter Extension

extension CodeSyntaxHighlighter where Self == HighlightCodeSyntaxHighlighter {
  /// Creates a syntax highlighter using HighlightSwift with theme-aware colors
  static func highlightSwift(colorScheme: ColorScheme) -> Self {
    HighlightCodeSyntaxHighlighter(colorScheme: colorScheme)
  }
}
