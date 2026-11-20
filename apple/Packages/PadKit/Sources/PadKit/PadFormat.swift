import Foundation

/// The numbers the menu bar and the popover show, formatted in one place.
public enum PadFormat {
  /// "420 m" below a kilometre, "1.24 km" above.
  public static func distance(_ meters: Double, locale: Locale = .current) -> String {
    if meters < 1000 {
      return "\(Int(meters.rounded()).formatted(.number.locale(locale))) m"
    }
    let kilometres = (meters / 1000).formatted(.number.precision(.fractionLength(2)).locale(locale))
    return "\(kilometres) km"
  }

  /// "4:05", "1:02:03".
  public static func duration(_ seconds: Int) -> String {
    let total = max(seconds, 0)
    let hours = total / 3600
    let minutes = total % 3600 / 60
    let rest = total % 60
    let two = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
    return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(minutes):\(two(rest))"
  }

  /// "3.5", without the unit.
  public static func speed(_ kmh: Double, locale: Locale = .current) -> String {
    kmh.formatted(.number.precision(.fractionLength(1)).locale(locale))
  }

  public static func steps(_ count: Int, locale: Locale = .current) -> String {
    count.formatted(.number.locale(locale))
  }

  public static func kcal(_ value: Double, locale: Locale = .current) -> String {
    "\(Int(value.rounded()).formatted(.number.locale(locale))) kcal"
  }
}

/// A walk's totals: the session in flight, or today's.
public struct WalkTotals: Equatable, Sendable {
  public let durationS: Int
  public let distanceM: Double
  public let steps: Int
  public let kcal: Double

  public init(durationS: Int, distanceM: Double, steps: Int, kcal: Double) {
    self.durationS = durationS
    self.distanceM = distanceM
    self.steps = steps
    self.kcal = kcal
  }

  public init(_ session: CurrentSession) {
    self.init(
      durationS: session.durationS, distanceM: session.distanceM, steps: session.steps,
      kcal: session.kcal)
  }

  /// Today so far: the host's `today` counts closed sessions only, so the open one is added.
  public init(today status: Status) {
    let day = status.today
    let open = status.currentSession.map(WalkTotals.init) ?? .zero
    self.init(
      durationS: day.durationS + open.durationS, distanceM: day.distanceM + open.distanceM,
      steps: day.steps + open.steps, kcal: day.kcal + open.kcal)
  }

  public static let zero = WalkTotals(durationS: 0, distanceM: 0, steps: 0, kcal: 0)
}

/// What the menu bar item shows: an SF Symbol and, when there is data, a short text.
public struct MenuBarContent: Equatable, Sendable {
  public let symbol: String
  public let text: String?

  /// Speed, elapsed time and distance while walking; today's distance otherwise; no text and a
  /// distinct symbol when there is no host or no pad.
  public init(phase: PadPhase, status: Status?, speed: Double, locale: Locale = .current) {
    switch phase {
    case .unconfigured:
      self.init(symbol: "gearshape", text: nil)
    case .connecting, .hostUnreachable:
      self.init(symbol: "network.slash", text: nil)
    case .unauthorized:
      self.init(symbol: "lock", text: nil)
    case .padDisconnected:
      self.init(symbol: "antenna.radiowaves.left.and.right.slash", text: nil)
    case .starting, .active, .stopping:
      let session = status?.currentSession
      let parts = [
        "\(PadFormat.speed(speed, locale: locale)) km/h",
        session.map { PadFormat.duration($0.durationS) },
        session.map { PadFormat.distance($0.distanceM, locale: locale) },
      ]
      self.init(symbol: "figure.walk", text: parts.compactMap(\.self).joined(separator: " · "))
    case .standby:
      let today = status.map { WalkTotals(today: $0) } ?? .zero
      self.init(symbol: "figure.stand", text: PadFormat.distance(today.distanceM, locale: locale))
    }
  }

  public init(symbol: String, text: String?) {
    self.symbol = symbol
    self.text = text
  }

  /// Every symbol the menu bar can show, for the test that each exists.
  public static let allSymbols = [
    "gearshape", "network.slash", "lock", "antenna.radiowaves.left.and.right.slash", "figure.walk",
    "figure.stand",
  ]
}

/// What the user types as the host's address.
public enum HostAddress {
  /// An http or https URL with a host; surrounding blanks and a trailing slash are dropped. A bare
  /// "host:port" gets http.
  public static func parse(_ raw: String) -> URL? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") { text = "http://" + text }
    guard var components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else { return nil }
    while components.path.hasSuffix("/") { components.path.removeLast() }
    return components.url
  }
}
