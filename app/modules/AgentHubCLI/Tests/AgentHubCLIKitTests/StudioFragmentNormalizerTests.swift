import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("StudioFragmentNormalizer")
struct StudioFragmentNormalizerTests {
  @Test("A full document is reduced to its body fragment with styles hoisted")
  func documentBecomesFragment() {
    let out = StudioFragmentNormalizer.normalize("""
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>x</title>
        <style>.btn { color: red; }</style>
      </head>
      <body class="dark">
        <button class="btn">Go</button>
      </body>
      </html>
      """)
    #expect(out.html == "<button class=\"btn\">Go</button>")
    #expect(out.css == ".btn { color: red; }")
    #expect(out.warnings.isEmpty)
  }

  @Test("Scripts are stripped and reported")
  func scriptsAreStripped() {
    let out = StudioFragmentNormalizer.normalize("<div>a</div><script>alert(1)</script><SCRIPT src=\"x.js\"></SCRIPT>")
    #expect(out.html == "<div>a</div>")
    #expect(out.warnings.count == 1)
    #expect(out.warnings[0].contains("2 <script>"))
  }

  @Test("External stylesheets are dropped and reported")
  func externalStylesheetsAreDropped() {
    let out = StudioFragmentNormalizer.normalize("<link rel=\"stylesheet\" href=\"a.css\"><p>x</p>")
    #expect(out.html == "<p>x</p>")
    #expect(out.warnings.count == 1)
    #expect(out.warnings[0].contains("external stylesheet"))
  }

  @Test("Multiple style blocks are concatenated in order")
  func multipleStylesConcatenate() {
    let out = StudioFragmentNormalizer.normalize("<style>a{}</style><b>x</b><style media=\"screen\">b{}</style>")
    #expect(out.html == "<b>x</b>")
    #expect(out.css == "a{}\n\nb{}")
  }

  @Test("A commented-out script is not reported as stripped")
  func commentedScriptIsNotReported() {
    let out = StudioFragmentNormalizer.normalize("<!-- <script>x</script> --><i>y</i>")
    #expect(out.html == "<i>y</i>")
    #expect(out.warnings.isEmpty)
  }

  @Test("A bare fragment passes through untouched")
  func fragmentPassesThrough() {
    let out = StudioFragmentNormalizer.normalize("<button class=\"x\">Go</button>")
    #expect(out.html == "<button class=\"x\">Go</button>")
    #expect(out.css.isEmpty)
  }
}
