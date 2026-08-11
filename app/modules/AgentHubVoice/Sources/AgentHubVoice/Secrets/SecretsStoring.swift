import Foundation

public protocol SecretsStoring: Sendable {
  func value(for account: String) async throws -> String?
  func setValue(_ value: String, for account: String) async throws
  func deleteValue(for account: String) async throws
}
