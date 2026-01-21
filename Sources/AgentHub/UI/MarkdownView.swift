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

  public init(content: String) {
    self.content = content
  }

  public var body: some View {
    ScrollView {
      Markdown(content)
        .markdownTheme(.agentHub)
        .markdownCodeSyntaxHighlighter(.plainText)
        .textSelection(.enabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color.surfaceCanvas)
  }
}

// MARK: - AgentHub Markdown Theme

extension MarkdownUI.Theme {
  /// Custom theme for plan markdown display
  static let agentHub = Theme()
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.9))
    }
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
    }
    .blockquote { configuration in
      HStack(spacing: 0) {
        Rectangle()
          .fill(Color.secondary.opacity(0.3))
          .frame(width: 3)
        configuration.label
          .padding(.leading, DesignTokens.Spacing.md)
      }
      .padding(.vertical, DesignTokens.Spacing.xs)
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
