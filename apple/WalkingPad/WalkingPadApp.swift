import PadKit
import SwiftUI

@main
struct WalkingPadApp: App {
  @State private var model = HostModel(
    client: PadClient(baseURL: HostModel.defaultHostURL))

  var body: some Scene {
    MenuBarExtra("WalkingPad", systemImage: "figure.walk") {
      PopoverView(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}
