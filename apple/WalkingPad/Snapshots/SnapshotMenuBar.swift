#if SNAPSHOT_HARNESS
  import PadKit
  import SwiftUI

  extension SnapshotRunner {
    /// The menu bar title as it draws for each choice of values, on a bar-coloured strip.
    func drawMenuBar(dark: Bool) async -> Int {
      struct Choice {
        let name: String
        let scenario: String
        let values: MenuBarValues
      }
      let choices = [
        Choice(name: "walking-all", scenario: "active", values: .all),
        Choice(name: "walking-steps", scenario: "active", values: .steps),
        Choice(name: "walking-none", scenario: "active", values: []),
        Choice(name: "idle-all", scenario: "standby", values: .all),
      ]
      var failures = 0
      for choice in choices {
        guard let scenario = Self.scenarios.first(where: { $0.name == choice.scenario }) else {
          return 1
        }
        let store = await popoverStore(scenario)
        failures += await draw(
          AnyView(MenuBarStrip(store: store, values: choice.values)),
          name: "menubar-\(choice.name)",
          width: 560, height: 28, isPopover: true, dark: dark)
      }
      return failures
    }

  }

  /// What MenuBarLabel draws, side by side with the neighbours a menu bar has, so the width reads.
  struct MenuBarStrip: View {
    let store: PadStore
    let values: MenuBarValues

    var body: some View {
      let content = MenuBarContent(
        phase: store.phase, status: store.status, speed: store.displayedSpeed, values: values)
      HStack(spacing: 4) {
        Spacer()
        Image(systemName: content.symbol)
        if let text = content.text { Text(text).monospacedDigit() }
        Image(systemName: "wifi").padding(.leading, 10)
        Image(systemName: "battery.75percent")
        Text("Sun 22 Nov 14:05").padding(.leading, 6)
      }
      .font(.system(size: 13))
      .padding(.horizontal, 10)
      .frame(width: 560, height: 28)
      .background(.bar)
    }
  }

#endif
