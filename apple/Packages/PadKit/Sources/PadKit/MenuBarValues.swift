import Foundation

/// The numbers the menu bar title can show. The user picks any of them in Settings.
public struct MenuBarValues: OptionSet, Hashable, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let speed = MenuBarValues(rawValue: 1)
  public static let time = MenuBarValues(rawValue: 2)
  public static let distance = MenuBarValues(rawValue: 4)
  public static let steps = MenuBarValues(rawValue: 8)

  public static let all: MenuBarValues = [.speed, .time, .distance, .steps]
}

/// Launch at login as the Settings toggle shows it. The app maps `SMAppService.Status` onto it;
/// the toggle is never disabled, because `notFound` is what macOS reports for an app that has not
/// registered yet and the only way to learn more is to try.
public enum LoginItemState: Equatable, Sendable {
  case enabled, requiresApproval, disabled, notFound

  /// The toggle reads on: registered, or registered and waiting for the user's approval.
  public var isOn: Bool { self == .enabled || self == .requiresApproval }

  /// The sentence under the toggle; nil when there is nothing to say.
  public var note: String? {
    switch self {
    case .enabled, .disabled: nil
    case .requiresApproval: "Allow WalkingPad in System Settings › General › Login Items."
    case .notFound:
      "macOS does not list this copy of WalkingPad as a login item. "
        + "Run it from Applications, then switch this on again."
    }
  }
}
