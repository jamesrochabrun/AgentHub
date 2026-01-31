//
//  MarkdownView.swift
//  AgentHub
//
//  Created by Assistant on 1/20/26.
//

import MarkdownUI
import SwiftUI

// MARK: - MarkdownView

/// A SwiftUI view that renders markdown content using MarkdownUI.
///
/// Wraps the MarkdownUI library's Markdown view with custom theming
/// to match the AgentHub design system.
public struct MarkdownView: View {
  let content: String
  let includeScrollView: Bool

  @Environment(\.colorScheme) private var colorScheme

  public init(content: String, includeScrollView: Bool = true) {
    self.content = content
    self.includeScrollView = includeScrollView
  }

  public var body: some View {
    if includeScrollView {
      ScrollView {
        markdownContent
      }
      .background(Color.surfaceCanvas)
    } else {
      markdownContent
    }
  }

  private var markdownContent: some View {
    Markdown(content)
      .markdownTheme(.agentHub)
      .markdownCodeSyntaxHighlighter(.highlightSwift(colorScheme: colorScheme))
      .textSelection(.enabled)
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - AgentHub Markdown Theme

extension MarkdownUI.Theme {
  /// Custom theme for plan markdown display
  static let agentHub = Theme()
    // MARK: - Headings
    .heading1 { configuration in
      configuration.label
        .markdownTextStyle {
          FontWeight(.bold)
          FontSize(.em(2.0))
        }
        .markdownMargin(top: .em(1.5), bottom: .em(0.5))
    }
    .heading2 { configuration in
      configuration.label
        .markdownTextStyle {
          FontWeight(.semibold)
          FontSize(.em(1.6))
        }
        .markdownMargin(top: .em(1.25), bottom: .em(0.375))
    }
    .heading3 { configuration in
      configuration.label
        .markdownTextStyle {
          FontWeight(.semibold)
          FontSize(.em(1.35))
        }
        .markdownMargin(top: .em(1.0), bottom: .em(0.25))
    }
    .heading4 { configuration in
      configuration.label
        .markdownTextStyle {
          FontWeight(.semibold)
          FontSize(.em(1.2))
        }
        .markdownMargin(top: .em(0.75), bottom: .em(0.25))
    }
    .heading5 { configuration in
      configuration.label
        .markdownTextStyle {
          FontWeight(.medium)
          FontSize(.em(1.1))
        }
        .markdownMargin(top: .em(0.5), bottom: .em(0.25))
    }
    .heading6 { configuration in
      configuration.label
        .markdownTextStyle {
          FontWeight(.medium)
          FontSize(.em(1.0))
          ForegroundColor(.secondary)
        }
        .markdownMargin(top: .em(0.5), bottom: .em(0.25))
    }
    // MARK: - Paragraph
    .paragraph { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(.em(1.1))
        }
        .lineSpacing(6)
        .markdownMargin(top: .zero, bottom: .em(0.75))
    }
    // MARK: - Inline Code
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.95))
      BackgroundColor(Color.surfaceCard.opacity(0.6))
    }
    // MARK: - Code Block
    .codeBlock { configuration in
      ScrollView(.horizontal, showsIndicators: true) {
        configuration.label
          .markdownTextStyle {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
          }
          .padding(DesignTokens.Spacing.md)
      }
      .background(Color.surfaceCard)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
      .markdownMargin(top: .em(0.5), bottom: .em(0.75))
    }
    // MARK: - Blockquote
    .blockquote { configuration in
      HStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.brandPrimary)
          .frame(width: 4)
        configuration.label
          .markdownTextStyle {
            FontStyle(.italic)
            ForegroundColor(.secondary)
          }
          .padding(.leading, DesignTokens.Spacing.md)
      }
      .padding(.vertical, DesignTokens.Spacing.xs)
      .markdownMargin(top: .em(0.5), bottom: .em(0.5))
    }
    // MARK: - Links
    .link {
      ForegroundColor(Color.brandPrimary)
    }
    // MARK: - Lists
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: .em(0.125), bottom: .em(0.125))
    }
    // MARK: - Thematic Break (Horizontal Rule)
    .thematicBreak {
      Divider()
        .markdownMargin(top: .em(1.0), bottom: .em(1.0))
    }
    // MARK: - Table
    .table { configuration in
      configuration.label
        .markdownTableBorderStyle(
          .init(color: .borderSubtle, width: 1)
        )
        .markdownMargin(top: .em(0.5), bottom: .em(0.75))
    }
    .tableCell { configuration in
      configuration.label
        .markdownTextStyle {
          FontSize(.em(1.0))
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .padding(.horizontal, DesignTokens.Spacing.sm)
    }
}

// MARK: - Preview

#Preview {
  MarkdownView(content: """
    # Heading 1

    This is a paragraph with **bold**, *italic*, and `inline code`.

    ## Heading 2

    Here's a code block:

    ```swift
    func hello() {
      print("Hello, World!")
    }
    ```

    ### Lists

    Unordered list:
    - Item 1
    - Item 2
      - Nested item
    - Item 3

    Ordered list:
    1. First
    2. Second
    3. Third

    > This is a block quote
    > with multiple lines

    ---

    That's all!
    """)
  .frame(width: 600, height: 800)
}
