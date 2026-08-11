import Foundation

public actor InMemorySecretsStore: SecretsStoring {
  private var values: [String: String]

  public init(values: [String: String] = [:]) {
    self.values = values
  }

  public func value(for account: String) -> String? {
    values[account]
  }

  public func setValue(_ value: String, for account: String) {
    values[account] = value
  }

  public func deleteValue(for account: String) {
    values.removeValue(forKey: account)
  }
}
