import AppKit
import KeyboardShortcuts
import PadKit

/// The global hotkeys. KeyboardShortcuts registers them through Carbon, which needs no
/// Accessibility permission, and stores what the user records in UserDefaults.
extension KeyboardShortcuts.Name {
  /// Control-Option-Command-Delete (Hyper+Backspace).
  static let toggleBelt = Self(
    "toggleBelt", initial: .init(.delete, modifiers: [.control, .option, .command]))
  /// Control-Option-Command-Up.
  static let speedUp = Self(
    "speedUp", initial: .init(.upArrow, modifiers: [.control, .option, .command]))
  /// Control-Option-Command-Down.
  static let speedDown = Self(
    "speedDown", initial: .init(.downArrow, modifiers: [.control, .option, .command]))

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

/// Hands the stored shortcuts to PadKit's `HotkeyMigration`, which resets one that still equals a
/// previous default (the rule and its tests live there).
enum HotkeyDefaults {
  @MainActor
  static func migrate(defaults: UserDefaults = .standard) {
    // The shipped Names carry the initial shortcut a reset restores; a Name rebuilt from its string would not.
    let names = Dictionary(
      uniqueKeysWithValues: KeyboardShortcuts.Name.all.map { ($0.rawValue, $0) })
    HotkeyMigration.migrate(
      defaults: defaults,
      stored: { name in
        names[name].flatMap { KeyboardShortcuts.getShortcut(for: $0) }.map {
          HotkeyBinding(keyCode: $0.carbonKeyCode, modifiers: $0.carbonModifiers)
        }
      },
      reset: { name in names[name].map { KeyboardShortcuts.reset($0) } })
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
