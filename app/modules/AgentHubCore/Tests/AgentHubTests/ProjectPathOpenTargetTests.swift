import Foundation
import Testing
@testable import AgentHubCore

@Suite("ProjectPathOpenTarget")
struct ProjectPathOpenTargetTests {
  @Test func exposesExpectedBundleIdentifiers() {
    #expect(ProjectPathOpenTarget.finder.bundleIdentifier == "com.apple.finder")
    #expect(ProjectPathOpenTarget.cursor.bundleIdentifier == "com.todesktop.230313mzl4w4u92")
    #expect(ProjectPathOpenTarget.visualStudioCode.bundleIdentifier == "com.microsoft.VSCode")
    #expect(ProjectPathOpenTarget.sublimeText.bundleIdentifiers == ["com.sublimetext.4", "com.sublimetext.3"])
    #expect(ProjectPathOpenTarget.xcode.bundleIdentifier == "com.apple.dt.Xcode")
    #expect(ProjectPathOpenTarget.ghostty.bundleIdentifier == "com.mitchellh.ghostty")
    #expect(ProjectPathOpenTarget.terminal.bundleIdentifier == "com.apple.Terminal")
  }

  @Test func resolvesAvailabilityFromInjectedApplicationLookup() {
    let installed: Set<String> = [
      ProjectPathOpenTarget.finder.bundleIdentifier,
      ProjectPathOpenTarget.cursor.bundleIdentifier,
      ProjectPathOpenTarget.visualStudioCode.bundleIdentifier,
      "com.sublimetext.3",
      ProjectPathOpenTarget.ghostty.bundleIdentifier,
      ProjectPathOpenTarget.terminal.bundleIdentifier
    ]

    func applicationURL(for bundleIdentifier: String) -> URL? {
      installed.contains(bundleIdentifier)
        ? URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app")
        : nil
    }

    #expect(ProjectPathOpenTarget.finder.isInstalled(applicationURL: applicationURL))
    #expect(ProjectPathOpenTarget.cursor.isInstalled(applicationURL: applicationURL))
    #expect(ProjectPathOpenTarget.visualStudioCode.isInstalled(applicationURL: applicationURL))
    #expect(ProjectPathOpenTarget.sublimeText.isInstalled(applicationURL: applicationURL))
    #expect(!ProjectPathOpenTarget.xcode.isInstalled(applicationURL: applicationURL))
    #expect(ProjectPathOpenTarget.ghostty.isInstalled(applicationURL: applicationURL))
    #expect(ProjectPathOpenTarget.terminal.isInstalled(applicationURL: applicationURL))
  }
}
