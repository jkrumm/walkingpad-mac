import Foundation
import Testing

@testable import PadKit

@Suite struct HotkeyMigrationTests {
  private let hyper = HotkeyBinding.hyper
  private let shift = HotkeyBinding.shift
  private let delete = 51

  private func defaults(version: Int?) -> UserDefaults {
    let suite = UserDefaults(suiteName: "HotkeyMigrationTests-\(UUID().uuidString)") ?? .standard
    if let version { suite.set(version, forKey: HotkeyMigration.versionKey) }
    return suite
  }

  /// Runs the migration over `stored` and returns the Names it reset, sorted.
  private func resets(
    _ stored: [String: HotkeyBinding], version: Int?, in suite: UserDefaults? = nil
  ) -> [String] {
    var reset: [String] = []
    HotkeyMigration.migrate(
      defaults: suite ?? defaults(version: version), stored: { stored[$0] },
      reset: { reset.append($0) })
    return reset.sorted()
  }

  private let previousDefaults: [String: HotkeyBinding] = [
    "toggleBelt": .init(keyCode: 13, modifiers: HotkeyBinding.hyper),
    "speedUp": .init(keyCode: 126, modifiers: HotkeyBinding.hyper + 512),
    "speedDown": .init(keyCode: 125, modifiers: HotkeyBinding.hyper + 512),
  ]

  @Test func aPreviousDefaultMovesToTheNewOne() {
    #expect(resets(previousDefaults, version: 2) == ["speedDown", "speedUp", "toggleBelt"])
    #expect(resets(previousDefaults, version: nil) == ["speedDown", "speedUp", "toggleBelt"])
  }

  @Test func aRecordedShortcutStays() {
    let custom: [String: HotkeyBinding] = [
      "toggleBelt": .init(keyCode: 14, modifiers: hyper),
      "speedUp": .init(keyCode: 126, modifiers: hyper + shift + 131072),
      "speedDown": .init(keyCode: 40, modifiers: hyper),
    ]
    #expect(resets(custom, version: 2).isEmpty)
  }

  @Test func theNewDefaultsStay() {
    let current: [String: HotkeyBinding] = [
      "toggleBelt": .init(keyCode: delete, modifiers: hyper),
      "speedUp": .init(keyCode: 126, modifiers: hyper),
      "speedDown": .init(keyCode: 125, modifiers: hyper),
    ]
    #expect(resets(current, version: 2).isEmpty)
    #expect(resets(current, version: nil).isEmpty)
  }

  @Test func aClearedShortcutStaysCleared() {
    #expect(resets([:], version: 2).isEmpty)
  }

  @Test func anInstallAtVersionThreeIsUntouched() {
    #expect(resets(previousDefaults, version: HotkeyMigration.version).isEmpty)
  }

  @Test func runsOnce() {
    let suite = defaults(version: 2)
    #expect(resets(previousDefaults, version: nil, in: suite).count == 3)
    #expect(suite.integer(forKey: HotkeyMigration.versionKey) == HotkeyMigration.version)
    #expect(resets(previousDefaults, version: nil, in: suite).isEmpty)
  }
}
