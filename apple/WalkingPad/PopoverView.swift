import AppKit
import PadKit
import SwiftUI

/// Placeholder popover: the host connection state, refreshed each time it opens.
struct PopoverView: View {
  let model: HostModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("WalkingPad").font(.headline)
      Text(verbatim: model.state.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
      Divider()
      Button("Quit WalkingPad") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .padding()
    .frame(width: 260, alignment: .leading)
    .task { await model.refresh() }
  }
}
