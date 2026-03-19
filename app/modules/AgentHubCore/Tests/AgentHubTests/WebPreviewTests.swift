import Foundation
import Testing

@testable import AgentHubCore

private actor ProbeAttemptCounter {
  private var attempts = 0

  func nextAttempt() -> Int {
    attempts += 1
    return attempts
  }

  func current() -> Int {
    attempts
  }
}

private actor GenerationGate {
  private var remainingCurrentChecks: Int

  init(remainingCurrentChecks: Int) {
    self.remainingCurrentChecks = remainingCurrentChecks
  }

  func isCurrent() -> Bool {
    guard remainingCurrentChecks > 0 else { return false }
    remainingCurrentChecks -= 1
    return true
  }
}

@Suite("WebPreviewNavigationPolicy")
struct WebPreviewNavigationPolicyTests {

  @Test("Allows file URLs inside the project root")
  func allowsProjectFiles() {
    let root = URL(fileURLWithPath: "/tmp/project")
    let child = root.appendingPathComponent("pages/index.html")

    let decision = WebPreviewNavigationPolicy.decision(
      for: child,
      allowedProjectRoot: root,
      isMainFrameNavigation: true,
      opensInNewWindow: false
    )

    #expect(decision == .allow)
  }

  @Test("Rejects file URLs outside the project root")
  func rejectsFilesOutsideRoot() {
    let root = URL(fileURLWithPath: "/tmp/project")
    let outside = URL(fileURLWithPath: "/tmp/other/index.html")

    let decision = WebPreviewNavigationPolicy.decision(
      for: outside,
      allowedProjectRoot: root,
      isMainFrameNavigation: true,
      opensInNewWindow: false
    )

    if case .deny = decision {
      return
    }

    Issue.record("Expected navigation outside the project root to be denied.")
  }

  @Test("Allows localhost and loopback origins")
  func allowsLoopbackOrigins() {
    let urls = [
      URL(string: "http://localhost:3000")!,
      URL(string: "http://127.0.0.1:3000")!,
      URL(string: "http://[::1]:3000")!
    ]

    for url in urls {
      let decision = WebPreviewNavigationPolicy.decision(
        for: url,
        allowedProjectRoot: nil,
        isMainFrameNavigation: true,
        opensInNewWindow: false
      )
      #expect(decision == .allow)
    }
  }

  @Test("Opens non-local top-level navigations in the external browser")
  func opensExternalSitesOutsideTheApp() {
    let url = URL(string: "https://example.com/docs")!

    let decision = WebPreviewNavigationPolicy.decision(
      for: url,
      allowedProjectRoot: nil,
      isMainFrameNavigation: true,
      opensInNewWindow: false
    )

    #expect(decision == .openExternally(url))
  }
}

@Suite("DevServerReadinessProbe")
struct DevServerReadinessProbeTests {

  @Test("Waits for a successful probe before becoming ready")
  func waitsForReachability() async {
    let url = URL(string: "http://localhost:3000")!
    let attempts = ProbeAttemptCounter()
    let probe = DevServerReadinessProbe(expectedURL: url)

    let result = await probe.waitUntilReady(
      timeout: .milliseconds(50),
      pollInterval: .milliseconds(1),
      probe: { _ in
        await attempts.nextAttempt() >= 3
      },
      isCurrent: { true }
    )

    #expect(result == .ready(url))
    #expect(await attempts.current() >= 3)
  }

  @Test("Times out when the server never becomes reachable")
  func timesOutWhenNoCandidateResponds() async {
    let probe = DevServerReadinessProbe(expectedURL: URL(string: "http://localhost:3000")!)

    let result = await probe.waitUntilReady(
      timeout: .milliseconds(20),
      pollInterval: .milliseconds(2),
      probe: { _ in false },
      isCurrent: { true }
    )

    #expect(result == .timedOut)
  }

  @Test("Returns stale when a restart invalidates the generation")
  func returnsStaleWhenGenerationChanges() async {
    let gate = GenerationGate(remainingCurrentChecks: 1)
    let probe = DevServerReadinessProbe(expectedURL: URL(string: "http://localhost:3000")!)

    let result = await probe.waitUntilReady(
      timeout: .milliseconds(40),
      pollInterval: .milliseconds(1),
      probe: { _ in false },
      isCurrent: { await gate.isCurrent() }
    )

    #expect(result == .stale)
  }
}
