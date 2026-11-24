import Foundation

/// A stored global shortcut as Carbon holds it: a virtual key code and Carbon modifier bits.
/// PadKit has no KeyboardShortcuts dependency, so the app maps its shortcut type to this one.
public struct HotkeyBinding: Equatable, Sendable {
  public let keyCode: Int
  public let modifiers: Int

  public init(keyCode: Int, modifiers: Int) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// Carbon bits of Control, Option and Command: the Hyper key.
  public static let hyper = 4096 + 2048 + 256
  static let shift = 512

  static let upArrow = 126
  static let downArrow = 125
  static let keyW = 13
}

/// KeyboardShortcuts writes a Name's initial shortcut into UserDefaults on first read, so changing a
/// default reaches no existing install. One time per version, a stored shortcut that still equals a
/// previous default is reset to the current one; anything the user recorded stays.
public enum HotkeyMigration {
  public static let versionKey = "hotkeyDefaultsVersion"
  public static let version = 3

  /// Every default a shortcut shipped with before the current one, by Name. Version 3 moved the
  /// speeds from Hyper+Shift+Up/Down (Tinycast held the plain arrows for Spotify's volume) to
  /// Hyper+Up/Down, and the toggle from Hyper+W to Hyper+Delete. The very first speed default,
  /// Hyper+Up/Down, equals the current one and needs no entry.
  static let previousDefaults: [String: [HotkeyBinding]] = [
    "toggleBelt": [.init(keyCode: HotkeyBinding.keyW, modifiers: HotkeyBinding.hyper)],
    "speedUp": [
      .init(keyCode: HotkeyBinding.upArrow, modifiers: HotkeyBinding.hyper + HotkeyBinding.shift)
    ],
    "speedDown": [
      .init(keyCode: HotkeyBinding.downArrow, modifiers: HotkeyBinding.hyper + HotkeyBinding.shift)
    ],
  ]

  /// Resets each stored shortcut that equals a previous default, once: an install already at the
  /// current version is untouched. `stored` reads a Name's shortcut, `reset` restores its initial one.
  public static func migrate(
    defaults: UserDefaults,
    stored: (String) -> HotkeyBinding?,
    reset: (String) -> Void
  ) {
    guard defaults.integer(forKey: versionKey) < version else { return }
    defaults.set(version, forKey: versionKey)
    for (name, previous) in previousDefaults.sorted(by: { $0.key < $1.key }) {
      guard let binding = stored(name), previous.contains(binding) else { continue }
      reset(name)
    }
  }
}
