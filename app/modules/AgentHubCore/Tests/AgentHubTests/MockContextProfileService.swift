import Foundation

@testable import AgentHubCore

/// Shared protocol mock for context-profile consumers (launcher, builder,
/// Project Details tab).
final class MockContextProfileService: ContextProfileServiceProtocol, @unchecked Sendable {
  var storedProfiles: [ContextProfile] = []
  var defaultProfileResult: ContextProfile?
  private(set) var savedProfiles: [ContextProfile] = []
  private(set) var deletedIds: [String] = []
  private(set) var defaultRequests: [String?] = []

  func profiles(forProjectPath projectPath: String) async throws -> [ContextProfile] {
    storedProfiles
  }

  func save(_ profile: ContextProfile) async throws {
    savedProfiles.append(profile)
    storedProfiles.removeAll { $0.id == profile.id }
    storedProfiles.append(profile)
  }

  func delete(id: String, projectPath: String) async throws {
    deletedIds.append(id)
    storedProfiles.removeAll { $0.id == id }
  }

  func setDefault(id: String?, forProjectPath projectPath: String) async throws {
    defaultRequests.append(id)
    storedProfiles = storedProfiles.map { profile in
      var updated = profile
      updated.isDefault = profile.id == id
      return updated
    }
  }

  func defaultProfile(forProjectPath projectPath: String) async throws -> ContextProfile? {
    defaultProfileResult ?? storedProfiles.first { $0.isDefault }
  }
}
