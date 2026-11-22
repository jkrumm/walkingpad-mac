import PadKit
import SwiftUI

/// The menu bar item: a symbol for the state and the values Settings chose, while walking or idle.
/// A MenuBarExtra label draws only Image and Text.
struct MenuBarLabel: View {
  let store: PadStore
  let settings: SettingsModel

  var body: some View {
    let content = MenuBarContent(
      phase: store.phase, status: store.status, speed: store.displayedSpeed,
      values: settings.menuBarValues)
    Image(systemName: content.symbol)
    if let text = content.text {
      Text(text).monospacedDigit()
    }
  }
}
