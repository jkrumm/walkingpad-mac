#if SNAPSHOT_HARNESS
  import AppKit
  import PadKit
  import SwiftUI

  /// The entry point of the snapshot build: `WalkingPad --ui-snapshot <dir>` draws the popover in
  /// every state, the Settings window and the History window, light and dark, and exits 0, or 1 when an image failed.
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
        failures += await drawMenuBar(dark: dark)
        failures += await drawSettings(dark: dark)
        failures += await drawHistory(dark: dark)
        failures += await drawLive(dark: dark)
        failures += await drawLiveHistory(dark: dark)
      }
      print("wrote snapshots to \(output.path), \(failures) failed")
      return failures
    }

    func popoverStore(_ scenario: Scenario) async -> PadStore {
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
        AnyView(SettingsView(model: model, checksHotkeys: false)), name: "settings", width: 460,
        isPopover: false,
        dark: dark)
    }

    /// One History window state: what the stub host answers for the four reads.
    struct HistoryScenario {
      let name: String
      let answer: SnapshotHost.Answer
      let routes: [String: SnapshotHost.Answer]
      var range = HistoryRange.days30
    }

    private func historyScenarios() -> [HistoryScenario] {
      let busy = SnapshotHistory()
      // The last walk is older than the 90 days of the chart: walks exist, the chart is empty.
      let quiet = SnapshotHistory(quietDays: 120)
      return [
        HistoryScenario(
          name: "history-30", answer: .json(SnapshotStatus.standby), routes: busy.routes()),
        HistoryScenario(
          name: "history-90", answer: .json(SnapshotStatus.standby), routes: busy.routes(),
          range: .days90),
        HistoryScenario(
          name: "history-quiet", answer: .json(SnapshotStatus.standby), routes: quiet.routes()),
        HistoryScenario(
          name: "history-empty", answer: .json(SnapshotStatus.standby),
          routes: SnapshotHistory.emptyRoutes),
        HistoryScenario(name: "history-unreachable", answer: .unreachable, routes: [:]),
        HistoryScenario(
          name: "history-unauthorized",
          answer: .http(401, #"{"error":"missing or bad bearer token"}"#), routes: [:]),
      ]
    }

    private func historyStore(
      _ scenario: HistoryScenario, extraRoutes: [String: SnapshotHost.Answer] = [:]
    ) async -> HistoryStore? {
      guard let base = Self.base else { return nil }
      let host = SnapshotHost(
        status: scenario.answer, routes: scenario.routes.merging(extraRoutes) { $1 })
      let client = PadClient(baseURL: base, transport: host)
      let history = HistoryStore(
        client: { client }, calendar: SnapshotHistory.calendar, now: { SnapshotHistory.now })
      history.range = scenario.range
      await history.reload()
      return history
    }

    private func drawHistory(dark: Bool) async -> Int {
      var failures = 0
      for scenario in historyScenarios() {
        guard let history = await historyStore(scenario) else { return 1 }
        failures += await draw(
          AnyView(HistoryView(model: history)), name: scenario.name, width: 560, height: 720,
          isPopover: false, dark: dark, title: "WalkingPad History")
      }
      // The detail of the newest walk, with its samples.
      let data = SnapshotHistory()
      if let walk = data.walks.first,
        let history = await historyStore(
          historyScenarios()[0], extraRoutes: data.detailRoute(for: walk)),
        let session = history.sessions.first
      {
        failures += await draw(
          AnyView(SessionDetailView(history: history, session: session) {}),
          name: "history-detail", width: 560, height: 720, isPopover: false, dark: dark,
          title: "WalkingPad History")
      }
      return failures
    }

    /// The History window against a running host (GETs only). `SNAP_LIVE_NOW=YYYY-MM-DD` puts
    /// "today" there, to see the window with the last stored walks when the host's data is old.
    private func drawLiveHistory(dark: Bool) async -> Int {
      guard let raw = ProcessInfo.processInfo.environment["SNAP_LIVE_URL"], !raw.isEmpty,
        let url = HostAddress.parse(raw)
      else { return 0 }
      let token = ProcessInfo.processInfo.environment["SNAP_LIVE_TOKEN"]
      let client = PadClient(baseURL: url, token: token)
      let calendar = Calendar.current
      var today = Date()
      if let text = ProcessInfo.processInfo.environment["SNAP_LIVE_NOW"],
        let day = HistoryDates.date(text, calendar: calendar)
      {
        today = day.addingTimeInterval(12 * 3600)
      }
      let moment = today
      let history = HistoryStore(client: { client }, calendar: calendar, now: { moment })
      await history.reload()
      print(
        "live history: \(history.load) sessions=\(history.sessions.count)"
          + " week=\(history.week.map { PadFormat.distance($0.distanceM) } ?? "-")"
          + " month=\(history.month.map { PadFormat.distance($0.distanceM) } ?? "-")"
          + " days=\(history.days.count) walkDays=\(history.days.filter { $0.sessions > 0 }.count)")
      var failures = await draw(
        AnyView(HistoryView(model: history)), name: "history-live", width: 560, height: 720,
        isPopover: false, dark: dark, title: "WalkingPad History")
      if let session = history.sessions.first(where: { $0.endedAt != nil }) {
        failures += await draw(
          AnyView(SessionDetailView(history: history, session: session) {}),
          name: "history-live-detail", width: 560, height: 720, isPopover: false, dark: dark,
          title: "WalkingPad History")
      }
      return failures
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

    func draw(
      _ content: AnyView, name: String, width: CGFloat, height: CGFloat? = nil, isPopover: Bool,
      dark: Bool, title: String = "WalkingPad Settings"
    ) async -> Int {
      let framed =
        isPopover
        ? AnyView(
          content.background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        : content
      let renderer = SnapshotRenderer(
        content: framed, width: width, height: height, isPopover: isPopover, dark: dark,
        title: title)
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
