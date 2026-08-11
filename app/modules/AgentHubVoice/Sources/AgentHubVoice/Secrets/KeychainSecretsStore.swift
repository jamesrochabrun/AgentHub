import Foundation
import Security

public enum KeychainSecretsStoreError: LocalizedError {
  case unhandledStatus(OSStatus)
  case invalidData

  public var errorDescription: String? {
    switch self {
    case .unhandledStatus(let status):
      SecCopyErrorMessageString(status, nil) as String?
        ?? "Keychain operation failed with status \(status)."
    case .invalidData:
      "The keychain value was not valid UTF-8 text."
    }
  }
}

public actor KeychainSecretsStore: SecretsStoring {
  public static let service = "com.agenthub.secrets"

  private let service: String

  public init(service: String = KeychainSecretsStore.service) {
    self.service = service
  }

  public func value(for account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainSecretsStoreError.unhandledStatus(status)
    }
    guard let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
      throw KeychainSecretsStoreError.invalidData
    }
    return value
  }

  public func setValue(_ value: String, for account: String) throws {
    let data = Data(value.utf8)
    let query = baseQuery(account: account)
    let attributes = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      attributes as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainSecretsStoreError.unhandledStatus(updateStatus)
    }

    var addQuery = query
    addQuery[kSecValueData as String] = data
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainSecretsStoreError.unhandledStatus(addStatus)
    }
  }

  public func deleteValue(for account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainSecretsStoreError.unhandledStatus(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
