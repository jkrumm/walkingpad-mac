import PadKit
import SwiftUI

/// The menu bar item: a symbol for the state and, while walking, speed, time and distance;
/// today's distance when idle. A MenuBarExtra label draws only Image and Text.
struct MenuBarLabel: View {
  let store: PadStore

  var body: some View {
    let content = MenuBarContent(
      phase: store.phase, status: store.status, speed: store.displayedSpeed)
    Image(systemName: content.symbol)
    if let text = content.text {
      Text(text).monospacedDigit()
    }
  }
}
