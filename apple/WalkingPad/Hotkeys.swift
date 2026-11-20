import KeyboardShortcuts
import PadKit

/// The global hotkeys. KeyboardShortcuts registers them through Carbon, which needs no
/// Accessibility permission, and stores what the user records in UserDefaults.
extension KeyboardShortcuts.Name {
  /// Control-Option-Command-W.
  static let toggleBelt = Self(
    "toggleBelt", initial: .init(.w, modifiers: [.control, .option, .command]))
  /// Control-Option-Command-Up.
  static let speedUp = Self(
    "speedUp", initial: .init(.upArrow, modifiers: [.control, .option, .command]))
  /// Control-Option-Command-Down.
  static let speedDown = Self(
    "speedDown", initial: .init(.downArrow, modifiers: [.control, .option, .command]))
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
