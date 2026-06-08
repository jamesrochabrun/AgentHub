import Testing

@testable import AgentHubMCPUI

@Suite("AgentHubMCPUIResource")
struct AgentHubMCPUIResourceTests {
  @Test("HTML app resources use the MCP app MIME profile")
  func htmlAppResourcesUseMCPAppMimeProfile() {
    let resource = AgentHubMCPUIResource(
      uri: "ui://agenthub/example",
      text: "<main>Example</main>"
    )

    #expect(resource.mimeType == "text/html;profile=mcp-app")
    #expect(resource.uri == "ui://agenthub/example")
    #expect(resource.text == "<main>Example</main>")
  }

  @Test("HTML escaping covers markup and quotes")
  func htmlEscapingCoversMarkupAndQuotes() {
    let escaped = AgentHubMCPUIHTML.escape("<script data-x=\"1\">'&'</script>")

    #expect(escaped == "&lt;script data-x=&quot;1&quot;&gt;&#39;&amp;&#39;&lt;/script&gt;")
  }
}
