import Foundation
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

  @Test("JSON values round-trip through Codable")
  func jsonValuesRoundTripThroughCodable() throws {
    let value = AgentHubMCPUIJSONValue.object([
      "method": .string("tools/call"),
      "params": .object([
        "enabled": .bool(true),
        "count": .number(2),
        "items": .array([.string("a"), .null])
      ])
    ])

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(AgentHubMCPUIJSONValue.self, from: data)

    #expect(decoded == value)
    #expect(decoded["params"]?["enabled"] == .bool(true))
  }

  @Test("JSONSerialization numbers are not bridged as booleans")
  func jsonSerializationNumbersAreNotBridgedAsBooleans() throws {
    let data = #"{"jsonrpc":"2.0","id":0,"params":{"enabled":false,"count":1}}"#.data(using: .utf8)!
    let object = try JSONSerialization.jsonObject(with: data)
    let value = AgentHubMCPUIJSONValue.fromJSONObject(object)

    #expect(value["id"] == .number(0))
    #expect(value["params"]?["enabled"] == .bool(false))
    #expect(value["params"]?["count"] == .number(1))
  }

  @Test("Bridge bootstrap captures parent postMessage fallback")
  @MainActor
  func bridgeBootstrapCapturesParentPostMessageFallback() {
    let script = AgentHubMCPUIWebView.Coordinator.bridgeBootstrapScript().source

    #expect(script.contains("window.postMessage = function"))
    #expect(script.contains("window.addEventListener('message'"))
    #expect(script.contains("forwardToNative(event.data)"))
    #expect(script.contains("event.origin === hostOrigin"))
  }
}

/// An MCP app's declared CSP domains come from the same untrusted tool output as
/// its HTML body. These tests pin the security invariant: DEFAULT-DENY — under
/// `.lockedDown` no remote directive (script, connect, img, …) names any declared
/// domain. Every remote directive, including `script-src` (real apps load their
/// runtime as ES modules from a CDN), widens only after explicit user consent and
/// only to validated http(s) hosts.
@Suite("MCP app CSP hardening")
@MainActor
struct MCPAppCSPHardeningTests {
  private let hostile = AgentHubMCPUICSP(
    connectDomains: ["https://attacker.com"],
    resourceDomains: ["https://attacker.com"]
  )

  @Test("Locked-down CSP names no declared domain in any directive")
  func lockedDownIgnoresDeclaredDomains() throws {
    let policy = AgentHubMCPUIWebView.cspContent(for: hostile, trust: .lockedDown)

    #expect(!policy.contains("attacker.com"))
    #expect(policy.contains("connect-src 'none'"))
    #expect(policy.contains("media-src 'none'"))
    // script-src is inline-only with no remote host until the user consents.
    let scriptDirective = try #require(
      policy.split(separator: ";").map(String.init).first { $0.contains("script-src") }
    )
    #expect(scriptDirective.contains("'unsafe-inline'"))
    #expect(!scriptDirective.contains("attacker.com"))
  }

  @Test("Consent widens script-src to the declared resource domains")
  func consentWidensScriptSrc() throws {
    let policy = AgentHubMCPUIWebView.cspContent(for: hostile, trust: .allowDeclaredDomains)

    let scriptDirective = try #require(
      policy.split(separator: ";").map(String.init).first { $0.contains("script-src") }
    )
    #expect(scriptDirective.contains("'unsafe-inline'"))
    #expect(scriptDirective.contains("https://attacker.com"))
  }

  @Test("Consent widens connect/img to the validated https domains")
  func consentWidensValidatedDomains() {
    let policy = AgentHubMCPUIWebView.cspContent(for: hostile, trust: .allowDeclaredDomains)

    #expect(policy.contains("connect-src https://attacker.com"))
    #expect(policy.contains("img-src data: blob: https://attacker.com"))
  }

  @Test("domainSources rejects non-http(s) schemes and hostless junk")
  func domainSourcesRejectsInvalidDomains() {
    let csp = AgentHubMCPUICSP(connectDomains: [
      "https://ok.com", "javascript:alert(1)", "file:///etc/passwd", "data:", "'self'"
    ])
    let policy = AgentHubMCPUIWebView.cspContent(for: csp, trust: .allowDeclaredDomains)

    #expect(policy.contains("https://ok.com"))
    #expect(policy.contains("'self'"))
    #expect(!policy.contains("javascript:"))
    #expect(!policy.contains("file:"))
  }

  @Test("Hardened HTML embeds the locked CSP and leaks no domains by default")
  func hardenedHTMLLockedByDefault() {
    let resource = AgentHubMCPUIResource(
      uri: "ui://x",
      text: "<head></head><body>x</body>",
      metadata: AgentHubMCPUIResourceMetadata(csp: hostile)
    )
    let html = AgentHubMCPUIWebView.hardenedHTML(for: resource, trust: .lockedDown)

    #expect(html.contains("Content-Security-Policy"))
    #expect(!html.contains("attacker.com"))
  }
}
