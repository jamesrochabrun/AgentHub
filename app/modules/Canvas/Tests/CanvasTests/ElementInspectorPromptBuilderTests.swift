import Testing
@testable import Canvas

@Suite("ElementInspectorPromptBuilder")
struct ElementInspectorPromptBuilderTests {

  @Test func includesOuterHTMLWhenPresent() {
    let element = TestFixtures.makeButton(
      outerHTML: "<button>Click</button>",
      computedStyles: [:]
    )
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(prompt.contains("**Element**: <button>Click</button>"))
  }

  @Test func fallsBackToLowercasedTagNameWhenOuterHTMLEmpty() {
    let element = TestFixtures.makeButton(tagName: "BUTTON", outerHTML: "", computedStyles: [:])
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(prompt.contains("**Element**: button"))
  }

  @Test func includesCSSSelector() {
    let element = TestFixtures.makeButton(cssSelector: "form > button.primary", computedStyles: [:])
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(prompt.contains("**CSS Selector**: form > button.primary"))
  }

  @Test func includesUserInstruction() {
    let element = TestFixtures.makeButton(computedStyles: [:])
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "make it red")
    #expect(prompt.contains("User request: make it red"))
  }

  @Test func includesClosingDirective() {
    let element = TestFixtures.makeButton(computedStyles: [:])
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(prompt.contains("Please modify the source code to make this change."))
  }

  @Test func filtersToRelevantStyleKeysOnly() {
    let element = TestFixtures.makeButton(
      computedStyles: [
        "color": "red",
        "font-family": "Arial",
        "z-index": "10",
        "opacity": "0.5",
      ]
    )
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(prompt.contains("color: red"))
    #expect(!prompt.contains("font-family"))
    #expect(!prompt.contains("z-index"))
    #expect(!prompt.contains("opacity"))
  }

  @Test func excludesStylesWithEmptyValues() {
    let element = TestFixtures.makeButton(
      computedStyles: ["color": "", "backgroundColor": "blue"]
    )
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(!prompt.contains("  color:"))
    #expect(prompt.contains("  backgroundColor: blue"))
  }

  @Test func omitsComputedStylesSectionWhenNoRelevantStyles() {
    let element = TestFixtures.makeButton(computedStyles: ["font-family": "Arial"])
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(!prompt.contains("**Computed Styles**"))
  }

  @Test func includesStylesHeaderWhenStylesExist() {
    let element = TestFixtures.makeButton(computedStyles: ["color": "red"])
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(prompt.contains("**Computed Styles**:"))
  }

  @Test func handlesCamelCaseStyleVariants() {
    let element = TestFixtures.makeButton(
      computedStyles: [
        "backgroundColor": "green",
        "fontSize": "18px",
        "borderRadius": "4px",
      ]
    )
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "test")
    #expect(prompt.contains("  backgroundColor: green"))
    #expect(prompt.contains("  fontSize: 18px"))
    #expect(prompt.contains("  borderRadius: 4px"))
  }

  @Test func correctLineOrdering() {
    let element = TestFixtures.makeButton(
      outerHTML: "<button>OK</button>",
      cssSelector: ".btn",
      computedStyles: ["color": "red"]
    )
    let prompt = ElementInspectorPromptBuilder.buildPrompt(element: element, instruction: "change color")
    let lines = prompt.components(separatedBy: "\n")

    #expect(lines[0] == "I'm looking at a web element in the live preview:")
    #expect(lines[1] == "")
    #expect(lines[2] == "**Element**: <button>OK</button>")
    #expect(lines[3] == "**CSS Selector**: .btn")
    #expect(lines[4] == "**Computed Styles**:")
    #expect(lines[5] == "  color: red")
    #expect(lines[6] == "")
    #expect(lines[7] == "User request: change color")
    #expect(lines[8] == "")
    #expect(lines[9] == "Please modify the source code to make this change.")
  }

  // MARK: - Context Prompt

  @Test func contextPromptIncludesElement() {
    let element = TestFixtures.makeButton(
      outerHTML: "<button>Click</button>",
      cssSelector: ".btn",
      computedStyles: [:]
    )
    let prompt = ElementInspectorPromptBuilder.buildContextPrompt(element: element)
    #expect(prompt.contains("**Element**: <button>Click</button>"))
    #expect(prompt.contains("**CSS Selector**: .btn"))
  }

  @Test func contextPromptOmitsUserRequest() {
    let element = TestFixtures.makeButton(computedStyles: [:])
    let prompt = ElementInspectorPromptBuilder.buildContextPrompt(element: element)
    #expect(!prompt.contains("User request"))
    #expect(!prompt.contains("Please modify the source code"))
  }

  @Test func contextPromptIncludesRelevantStyles() {
    let element = TestFixtures.makeButton(computedStyles: ["color": "red", "font-family": "Arial"])
    let prompt = ElementInspectorPromptBuilder.buildContextPrompt(element: element)
    #expect(prompt.contains("color: red"))
    #expect(!prompt.contains("font-family"))
  }

  @Test func contextPromptFallsBackToTagName() {
    let element = TestFixtures.makeButton(tagName: "DIV", outerHTML: "", computedStyles: [:])
    let prompt = ElementInspectorPromptBuilder.buildContextPrompt(element: element)
    #expect(prompt.contains("**Element**: div"))
  }

  @Test func multiElementPromptIncludesNumberedSections() {
    let elements = [
      TestFixtures.makeButton(
        outerHTML: "<button>Launch</button>",
        cssSelector: ".hero button",
        computedStyles: ["color": "white"]
      ),
      TestFixtures.makeButton(
        tagName: "SECTION",
        outerHTML: "<section class=\"pricing\"></section>",
        cssSelector: ".pricing",
        computedStyles: ["backgroundColor": "black"]
      ),
    ]

    let prompt = ElementInspectorPromptBuilder.buildPrompt(
      elements: elements,
      instruction: "Make these feel like one component"
    )

    #expect(prompt.contains("### Element 1"))
    #expect(prompt.contains("### Element 2"))
    #expect(prompt.contains(".hero button"))
    #expect(prompt.contains(".pricing"))
    #expect(prompt.contains("User request: Make these feel like one component"))
  }

  @Test func multiElementContextPromptIncludesNumberedSections() {
    let elements = [
      TestFixtures.makeButton(
        outerHTML: "<button>Launch</button>",
        cssSelector: ".hero button",
        computedStyles: ["color": "white"]
      ),
      TestFixtures.makeButton(
        tagName: "SECTION",
        outerHTML: "<section class=\"pricing\"></section>",
        cssSelector: ".pricing",
        computedStyles: ["backgroundColor": "black"]
      ),
    ]

    let prompt = ElementInspectorPromptBuilder.buildContextPrompt(elements: elements)

    #expect(prompt.contains("### Element 1"))
    #expect(prompt.contains("### Element 2"))
    #expect(prompt.contains(".hero button"))
    #expect(prompt.contains(".pricing"))
    #expect(!prompt.contains("User request"))
  }
}
