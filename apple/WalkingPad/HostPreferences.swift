import Foundation
import PadKit
import Security
import ServiceManagement

/// The host URL and the default start speed, in UserDefaults. `-hostURL <url>` on the command line
/// overrides the stored URL for one run (UserDefaults' argument domain).
struct HostPreferences {
  private enum Key {
    static let hostURL = "hostURL"
    static let startSpeed = "startSpeed"
  }

  let defaults: UserDefaults

  var hostURL: String {
    get { defaults.string(forKey: Key.hostURL) ?? "" }
    nonmutating set { defaults.set(newValue, forKey: Key.hostURL) }
  }

  var startSpeed: Double {
    get {
      let stored = defaults.double(forKey: Key.startSpeed)
      return stored == 0 ? SpeedRange.defaultStartSpeed : SpeedRange.clamp(stored)
    }
    nonmutating set { defaults.set(newValue, forKey: Key.startSpeed) }
  }
}

/// Where the host's bearer token is kept.
protocol TokenStore {
  func read() throws -> String?
  func save(_ token: String) throws
  func delete() throws
}

/// The token as a generic password in the login Keychain.
struct KeychainTokenStore: TokenStore {
  struct Failure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
      (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
  }

  private let identity: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: "com.jkrumm.walkingpad.client",
    kSecAttrAccount: "host-token",
  ]

  func read() throws -> String? {
    var query = identity
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
    return String(data: data, encoding: .utf8)
  }

  func save(_ token: String) throws {
    let data = Data(token.utf8)
    let update = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw Failure(status: update) }
    var attributes = identity
    attributes[kSecValueData] = data
    let add = SecItemAdd(attributes as CFDictionary, nil)
    guard add == errSecSuccess else { throw Failure(status: add) }
  }

  func delete() throws {
    let status = SecItemDelete(identity as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }
}

enum LoginItemState: Equatable {
  case enabled, requiresApproval, disabled, unavailable
}

/// Launch at login, behind a port so the snapshot build never registers the app.
protocol LoginItemControlling {
  func state() -> LoginItemState
  func setEnabled(_ enabled: Bool) throws -> LoginItemState
}

/// The app's own login item through `SMAppService.mainApp`; only the running bundle may use it.
struct SMAppServiceLoginItem: LoginItemControlling {
  func state() -> LoginItemState {
    Self.map(SMAppService.mainApp.status)
  }

  func setEnabled(_ enabled: Bool) throws -> LoginItemState {
    let service = SMAppService.mainApp
    if enabled {
      if service.status != .enabled { try service.register() }
    } else if service.status != .notRegistered {
      try service.unregister()
    }
    return Self.map(service.status)
  }

  private static func map(_ status: SMAppService.Status) -> LoginItemState {
    switch status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered: .disabled
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }
}
