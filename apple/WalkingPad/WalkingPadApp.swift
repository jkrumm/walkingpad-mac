import PadKit
import SwiftUI

/// The menu bar item with its popover, and the Settings window. A Window scene, not the Settings
/// scene: an accessory app cannot bring the Settings scene forward reliably (ntfy-mac's AGENTS.md).
#if !SNAPSHOT_HARNESS
  @main
#endif
struct WalkingPadApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra {
      PopoverView(store: delegate.store)
    } label: {
      MenuBarLabel(store: delegate.store)
    }
    .menuBarExtraStyle(.window)

    Window("WalkingPad Settings", id: SettingsView.windowID) {
      SettingsView(model: delegate.settings)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
  }
}

/// Builds the store, the settings and the hotkeys once, from the real adapters, and starts polling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store: PadStore
  let settings: SettingsModel
  private var polling: Task<Void, Never>?
  private var hotkeys: HotkeyListener?

  override init() {
    let preferences = HostPreferences(defaults: .standard)
    store = PadStore(client: nil, startSpeed: preferences.startSpeed)
    settings = SettingsModel(
      store: store, preferences: preferences, tokens: KeychainTokenStore(),
      loginItem: SMAppServiceLoginItem())
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    settings.connectSaved()
    let store = store
    polling = Task { await store.run() }
    hotkeys = HotkeyListener(store: store)
  }
}
