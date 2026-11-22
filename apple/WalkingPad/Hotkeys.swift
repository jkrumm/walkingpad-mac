import AppKit
import KeyboardShortcuts
import PadKit

/// The global hotkeys. KeyboardShortcuts registers them through Carbon, which needs no
/// Accessibility permission, and stores what the user records in UserDefaults.
extension KeyboardShortcuts.Name {
  /// Control-Option-Command-W.
  static let toggleBelt = Self(
    "toggleBelt", initial: .init(.w, modifiers: [.control, .option, .command]))
  /// Control-Option-Command-Shift-Up: Hyper+Up and Hyper+Down belong to Spotify's volume.
  static let speedUp = Self(
    "speedUp", initial: .init(.upArrow, modifiers: [.control, .option, .command, .shift]))
  /// Control-Option-Command-Shift-Down.
  static let speedDown = Self(
    "speedDown", initial: .init(.downArrow, modifiers: [.control, .option, .command, .shift]))

  static let all: [Self] = [.toggleBelt, .speedUp, .speedDown]

  /// A shortcut is set and the listener runs, yet Carbon holds no hotkey for it: another app has
  /// the combination (KeyboardShortcuts drops a failed registration without a word). Reading
  /// it needs the listener, so the snapshot build, which starts none, never asks.
  @MainActor var isBlocked: Bool {
    KeyboardShortcuts.getShortcut(for: self) != nil && !KeyboardShortcuts.isEnabled(for: self)
  }

  /// What a stored shortcut that is not the default means for the user, for the Reset button.
  @MainActor var isDefault: Bool { KeyboardShortcuts.getShortcut(for: self) == initialShortcut }
}

/// KeyboardShortcuts stores an initial shortcut the first time it reads it, so every install holds
/// the speed shortcuts it first shipped with, Control-Option-Command-Up and -Down, which a
/// Hyper-key setup uses for Spotify's volume. One time, a stored shortcut that still equals that
/// first default moves to the current default; anything else the user recorded stays.
enum HotkeyDefaults {
  private static let versionKey = "hotkeyDefaultsVersion"
  private static let version = 2

  @MainActor
  static func migrate(defaults: UserDefaults = .standard) {
    guard defaults.integer(forKey: versionKey) < version else { return }
    defaults.set(version, forKey: versionKey)
    let hyper: NSEvent.ModifierFlags = [.control, .option, .command]
    let first: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
      (.speedUp, .init(.upArrow, modifiers: hyper)),
      (.speedDown, .init(.downArrow, modifiers: hyper)),
    ]
    for (name, shortcut) in first where KeyboardShortcuts.getShortcut(for: name) == shortcut {
      KeyboardShortcuts.reset(name)
    }
  }
}

/// Forwards each press to the store. Every press runs on its own, so a held speed key queues
/// speeds the store coalesces instead of waiting for each request.
@MainActor
final class HotkeyListener {
  private var listeners: [Task<Void, Never>] = []

  init(store: PadStore) {
    listeners = [
      Task {
        for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleBelt) {
          Task { await store.toggle() }
        }
      },
      Task {
        for await _ in KeyboardShortcuts.repeatingKeyDownEvents(for: .speedUp) {
          Task { await store.changeSpeed(by: 1) }
        }
      },
      Task {
        for await _ in KeyboardShortcuts.repeatingKeyDownEvents(for: .speedDown) {
          Task { await store.changeSpeed(by: -1) }
        }
      },
    ]
  }
}
