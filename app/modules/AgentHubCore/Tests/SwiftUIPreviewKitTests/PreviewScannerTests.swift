import Foundation
import Testing
@testable import SwiftUIPreviewKit

// MARK: - extractPreviews

@Suite("PreviewScanner.extractPreviews")
struct ExtractPreviewsTests {

  @Test func parsesUnnamedPreview() {
    let source = """
    import SwiftUI

    #Preview {
      Text("Hello")
    }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.count == 1)
    #expect(results[0].name == nil)
    #expect(results[0].displayName == "Preview (line 3)")
    #expect(results[0].bodyExpression.contains("Text(\"Hello\")"))
    #expect(results[0].lineNumber == 3)
  }

  @Test func parsesNamedPreview() {
    let source = """
    #Preview("Card View") {
      VStack {
        Text("Title")
        Text("Subtitle")
      }
    }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: "MyApp")
    #expect(results.count == 1)
    #expect(results[0].name == "Card View")
    #expect(results[0].displayName == "Card View")
    #expect(results[0].moduleName == "MyApp")
    #expect(results[0].bodyExpression.contains("VStack"))
    #expect(results[0].bodyExpression.contains("Text(\"Title\")"))
  }

  @Test func parsesMultiplePreviewsInOneFile() {
    let source = """
    #Preview("First") {
      Text("A")
    }

    struct MyView: View {
      var body: some View { Text("hello") }
    }

    #Preview("Second") {
      Text("B")
    }

    #Preview {
      Text("C")
    }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.count == 3)
    #expect(results[0].name == "First")
    #expect(results[1].name == "Second")
    #expect(results[2].name == nil)
    #expect(results[0].lineNumber < results[1].lineNumber)
    #expect(results[1].lineNumber < results[2].lineNumber)
  }

  @Test func returnsEmptyForNoPreview() {
    let source = """
    import SwiftUI

    struct MyView: View {
      var body: some View {
        Text("Hello")
      }
    }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.isEmpty)
  }

  @Test func handlesStateInBody() {
    let source = """
    #Preview {
      @Previewable @State var count = 0
      VStack {
        Text("Count: \\(count)")
        Button("Increment") { count += 1 }
      }
    }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.count == 1)
    #expect(results[0].bodyExpression.contains("@Previewable @State var count"))
    #expect(results[0].bodyExpression.contains("Button"))
  }

  @Test func ignoresLineCommentedPreview() {
    let source = """
    // #Preview {
    //   Text("Commented out")
    // }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.isEmpty)
  }

  @Test func ignoresBlockCommentedPreview() {
    let source = """
    /*
    #Preview {
      Text("Block commented")
    }
    */
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.isEmpty)
  }

  @Test func handlesStringLiteralWithBraces() {
    let source = """
    #Preview {
      Text("Hello {world}")
    }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.count == 1)
    #expect(results[0].bodyExpression.contains("Text(\"Hello {world}\")"))
  }

  @Test func handlesNestedClosures() {
    let source = """
    #Preview {
      VStack {
        ForEach(0..<5) { i in
          Text("Item \\(i)")
        }
      }
    }
    """
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/tmp/Test.swift", moduleName: nil)
    #expect(results.count == 1)
    #expect(results[0].bodyExpression.contains("ForEach"))
    #expect(results[0].bodyExpression.contains("Text(\"Item"))
  }

  @Test func setsFilePathAndFileName() {
    let source = "#Preview { Text(\"Hi\") }"
    let results = PreviewScanner.extractPreviews(from: source, filePath: "/Users/dev/MyApp/ContentView.swift", moduleName: nil)
    #expect(results.count == 1)
    #expect(results[0].filePath == "/Users/dev/MyApp/ContentView.swift")
    #expect(results[0].fileName == "ContentView.swift")
  }
}

// MARK: - extractPreviewName

@Suite("PreviewScanner.extractPreviewName")
struct ExtractPreviewNameTests {

  @Test func extractsQuotedName() {
    #expect(PreviewScanner.extractPreviewName(from: "(\"My Preview\") {") == "My Preview")
  }

  @Test func returnsNilForNoParens() {
    #expect(PreviewScanner.extractPreviewName(from: " {") == nil)
  }

  @Test func returnsNilForNoQuotes() {
    #expect(PreviewScanner.extractPreviewName(from: "(traits: .sizeThatFitsLayout) {") == nil)
  }

  @Test func handlesSpacesInsideParens() {
    #expect(PreviewScanner.extractPreviewName(from: "(  \"Spaced\"  ) {") == "Spaced")
  }
}

// MARK: - isInsideBlockComment

@Suite("PreviewScanner.isInsideBlockComment")
struct IsInsideBlockCommentTests {

  @Test func detectsOpenBlockComment() {
    #expect(PreviewScanner.isInsideBlockComment("/* start of comment") == true)
  }

  @Test func detectsClosedBlockComment() {
    #expect(PreviewScanner.isInsideBlockComment("/* closed */ normal code") == false)
  }

  @Test func handlesNestedBlockComments() {
    #expect(PreviewScanner.isInsideBlockComment("/* outer /* inner */") == true)
  }

  @Test func noCommentReturnsFalse() {
    #expect(PreviewScanner.isInsideBlockComment("let x = 5") == false)
  }
}
