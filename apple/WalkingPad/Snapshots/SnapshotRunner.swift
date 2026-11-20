#if SNAPSHOT_HARNESS
  import AppKit
  import PadKit
  import SwiftUI

  /// The entry point of the snapshot build: `WalkingPad --ui-snapshot <dir>` draws the popover in
  /// every state and the Settings window, light and dark, and exits 0, or 1 when an image failed.
  /// `SNAP_LIVE_URL` adds the popover against a running host (GET /status only).
  @main
  enum SnapshotEntry {
    static func main() {
      let arguments = CommandLine.arguments
      guard let flag = arguments.firstIndex(of: "--ui-snapshot") else {
        WalkingPadApp.main()
        return
      }
      let next = arguments.index(after: flag)
      let output = URL(
        fileURLWithPath: next < arguments.endIndex ? arguments[next] : "apple/.snapshots",
        isDirectory: true)
      MainActor.assumeIsolated {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
          let failures = await SnapshotRunner(output: output).run()
          exit(failures == 0 ? 0 : 1)
        }
        application.run()
      }
    }
  }

  @MainActor
  struct SnapshotRunner {
    let output: URL

    /// One popover state: what the stub host answers, and whether a Start is in flight.
    struct Scenario {
      let name: String
      let answer: SnapshotHost.Answer?
      var startInFlight = false
    }

    static let base = URL(string: "http://127.0.0.1:7706")

    static let scenarios = [
      Scenario(name: "unconfigured", answer: nil),
      Scenario(name: "unreachable", answer: .unreachable),
      Scenario(
        name: "unauthorized", answer: .http(401, #"{"error":"missing or bad bearer token"}"#)),
      Scenario(name: "disconnected", answer: .json(SnapshotStatus.disconnected)),
      Scenario(name: "standby", answer: .json(SnapshotStatus.standby)),
      Scenario(name: "start-pending", answer: .json(SnapshotStatus.standby), startInFlight: true),
      Scenario(
        name: "starting",
        answer: .json(SnapshotStatus.walking("starting", speed: 0, durationS: 2, distanceM: 0))),
      Scenario(
        name: "active",
        answer: .json(
          SnapshotStatus.walking("active", speed: 4.5, durationS: 1564, distanceM: 1890))),
      Scenario(
        name: "stopping",
        answer: .json(
          SnapshotStatus.walking("stopping", speed: 1.5, durationS: 1802, distanceM: 2150))),
    ]

    func run() async -> Int {
      do {
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      } catch {
        print("cannot create \(output.path): \(error)")
        return 1
      }
      var failures = 0
      for dark in [false, true] {
        for scenario in Self.scenarios {
          let store = await popoverStore(scenario)
          failures += await draw(
            AnyView(PopoverView(store: store)), name: "popover-\(scenario.name)", width: 320,
            isPopover: true, dark: dark)
        }
        failures += await drawSettings(dark: dark)
        failures += await drawLive(dark: dark)
      }
      print("wrote snapshots to \(output.path), \(failures) failed")
      return failures
    }

    private func popoverStore(_ scenario: Scenario) async -> PadStore {
      guard let answer = scenario.answer, let base = Self.base else {
        return PadStore(client: nil)
      }
      let host = SnapshotHost(status: answer, holdWrites: scenario.startInFlight)
      let store = PadStore(client: PadClient(baseURL: base, transport: host), startSpeed: 3.0)
      await store.refresh()
      if scenario.startInFlight {
        Task { await store.start() }
        await Task.yield()
      }
      return store
    }

    private func drawSettings(dark: Bool) async -> Int {
      guard let base = Self.base,
        let defaults = UserDefaults(suiteName: "walkingpad-snapshot-\(UUID().uuidString)")
      else { return 1 }
      let preferences = HostPreferences(defaults: defaults)
      preferences.hostURL = base.absoluteString
      preferences.startSpeed = 3.5
      let store = PadStore(
        client: PadClient(
          baseURL: base, transport: SnapshotHost(status: .json(SnapshotStatus.standby))))
      await store.refresh()
      let model = SettingsModel(
        store: store, preferences: preferences, tokens: SnapshotTokens(),
        loginItem: SnapshotLoginItem())
      return await draw(
        AnyView(SettingsView(model: model)), name: "settings", width: 460, isPopover: false,
        dark: dark)
    }

    /// The popover against a running host, polled once: proof of what the app shows there.
    private func drawLive(dark: Bool) async -> Int {
      guard let raw = ProcessInfo.processInfo.environment["SNAP_LIVE_URL"], !raw.isEmpty else {
        return 0
      }
      guard let url = HostAddress.parse(raw) else {
        print("SNAP_LIVE_URL is not an http(s) URL: \(raw)")
        return 1
      }
      let token = ProcessInfo.processInfo.environment["SNAP_LIVE_TOKEN"]
      let store = PadStore(client: PadClient(baseURL: url, token: token))
      await store.refresh()
      let today = store.status.map { WalkTotals(today: $0) } ?? .zero
      print(
        "live \(url.absoluteString): phase=\(store.phase.title) belt=\(store.status?.beltState?.wire ?? "-")"
          + " today=\(PadFormat.distance(today.distanceM)) \(PadFormat.duration(today.durationS))"
          + " \(today.steps) steps")
      return await draw(
        AnyView(PopoverView(store: store)), name: "popover-live", width: 320, isPopover: true,
        dark: dark)
    }

    private func draw(_ content: AnyView, name: String, width: CGFloat, isPopover: Bool, dark: Bool)
      async -> Int
    {
      let framed =
        isPopover
        ? AnyView(
          content.background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        : content
      let renderer = SnapshotRenderer(
        content: framed, width: width, isPopover: isPopover, dark: dark)
      defer { renderer.close() }
      await renderer.settle()
      await renderer.settle(300)
      let file = "\(name)-\(dark ? "dark" : "light").png"
      guard let data = renderer.png() else {
        print("FAILED \(file): no image")
        return 1
      }
      do {
        try data.write(to: output.appending(path: file))
        print(file)
        return 0
      } catch {
        print("FAILED \(file): \(error)")
        return 1
      }
    }
  }

  /// No Keychain in the snapshot build.
  struct SnapshotTokens: TokenStore {
    func read() throws -> String? { "snapshot-token" }
    func save(_ token: String) throws {}
    func delete() throws {}
  }

  /// Never registers the snapshot build as a login item.
  struct SnapshotLoginItem: LoginItemControlling {
    func state() -> LoginItemState { .enabled }
    func setEnabled(_ enabled: Bool) throws -> LoginItemState { .enabled }
  }
#endif
