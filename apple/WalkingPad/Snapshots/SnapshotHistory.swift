#if SNAPSHOT_HARNESS
  import Foundation
  import PadKit

  /// A host's history in its wire shape (contracts/fixtures): sessions on most days of the last
  /// 90, with numbers like the real ones, so the window is judged with believable data. Fixed
  /// "now" and a UTC calendar keep the pictures reproducible.
  struct SnapshotHistory {
    /// 2026-11-20 09:40 UTC.
    static let now = Date(timeIntervalSince1970: 1_795_167_600)
    static let calendar: Calendar = {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = .gmt
      return calendar
    }()

    struct Walk {
      let uuid: String
      let startedAt: Date
      let durationS: Int
      let distanceM: Double
      var steps: Int { Int(distanceM * 1.43) }
      var kcal: Double { (distanceM / 19.7).rounded() }
    }

    /// Newest first. Nothing newer than `quietDays` days ago.
    let walks: [Walk]

    init(quietDays: Int = 0) {
      var walks: [Walk] = []
      for offset in quietDays..<200 where offset % 7 != 3 && offset % 11 != 5 {
        let day = Self.calendar.date(
          byAdding: .day, value: -offset, to: Self.calendar.startOfDay(for: Self.now))
        guard let day else { continue }
        let distances = [2100 + Double(offset * 397 % 3300), 1200 + Double(offset * 211 % 900)]
        let starts: [TimeInterval] = [18 * 3600 + 10 * 60, 7 * 3600 + 30 * 60]
        for (index, distance) in distances.enumerated() where index == 0 || offset % 4 == 0 {
          let start = day.addingTimeInterval(starts[index])
          guard start < Self.now else { continue }
          walks.append(
            Walk(
              uuid: String(format: "00000000-0000-4000-8000-%012d", offset * 10 + index),
              startedAt: start, durationS: Int(distance / 4.3 * 3.6), distanceM: distance))
        }
      }
      self.walks = walks.sorted { $0.startedAt > $1.startedAt }
    }

    private static func wire(_ date: Date) -> String { WireCoding.formatDate(date) }

    func sessionsJSON(limit: Int = 50) -> String {
      let items = walks.prefix(limit).map { walk -> String in
        let end = walk.startedAt.addingTimeInterval(Double(walk.durationS))
        return Self.sessionJSON(walk, end: Self.wire(end))
      }
      return #"{"sessions":[\#(items.joined(separator: ","))]}"#
    }

    private static func sessionJSON(_ walk: Walk, end: String) -> String {
      """
      {"uuid":"\(walk.uuid)","started_at":"\(wire(walk.startedAt))","ended_at":"\(end)",\
      "duration_s":\(walk.durationS),"distance_m":\(walk.distanceM),"steps":\(walk.steps),\
      "avg_speed_kmh":4.3,"max_speed_kmh":4.8,"kcal":\(walk.kcal),"pause_count":\(walk.durationS % 3),\
      "synced_at":"\(wire(walk.startedAt.addingTimeInterval(Double(walk.durationS) + 3600)))"}
      """
    }

    /// The walks that started from `first` (inclusive) on.
    private func total(since first: Date, period: String) -> String {
      let chosen = walks.filter { $0.startedAt >= first }
      let distance = chosen.reduce(0) { $0 + $1.distanceM }
      return """
        {"period":"\(period)","sessions":\(chosen.count),"duration_s":\(chosen.reduce(0) { $0 + $1.durationS }),\
        "distance_m":\(distance),"steps":\(chosen.reduce(0) { $0 + $1.steps }),\
        "kcal":\(chosen.reduce(0) { $0 + $1.kcal })}
        """
    }

    /// The window's four requests, answered from the walks.
    func routes() -> [String: SnapshotHost.Answer] {
      let calendar = Self.calendar
      let today = calendar.startOfDay(for: Self.now)
      let month = calendar.dateInterval(of: .month, for: Self.now)?.start ?? today
      return [
        "/sessions": .json(sessionsJSON()),
        "/summary?period=week": .json(total(since: Self.isoWeekStart(today), period: "week")),
        "/summary?period=month": .json(total(since: month, period: "month")),
        "/summary/days": .json(daysJSON()),
      ]
    }

    /// Monday of the week of `day`, as the host counts a week.
    private static func isoWeekStart(_ day: Date) -> Date {
      let offset = (calendar.component(.weekday, from: day) + 5) % 7
      return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    private func daysJSON() -> String {
      let calendar = Self.calendar
      let today = calendar.startOfDay(for: Self.now)
      let items = (0..<90).reversed().compactMap { offset -> String? in
        guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let chosen = walks.filter { calendar.startOfDay(for: $0.startedAt) == day }
        return """
          {"date":"\(HistoryDates.string(day, calendar: calendar))","sessions":\(chosen.count),\
          "duration_s":\(chosen.reduce(0) { $0 + $1.durationS }),\
          "distance_m":\(chosen.reduce(0) { $0 + $1.distanceM }),\
          "steps":\(chosen.reduce(0) { $0 + $1.steps }),"kcal":\(chosen.reduce(0) { $0 + $1.kcal })}
          """
      }
      let from = HistoryDates.string(
        calendar.date(byAdding: .day, value: -89, to: today) ?? today, calendar: calendar)
      let to = HistoryDates.string(today, calendar: calendar)
      return #"{"from":"\#(from)","to":"\#(to)","days":[\#(items.joined(separator: ","))]}"#
    }

    /// A walk's detail: a sample every 10 seconds, easing up to 4.5 km/h with a dip in the middle.
    func detailRoute(for walk: Walk) -> [String: SnapshotHost.Answer] {
      let end = walk.startedAt.addingTimeInterval(Double(walk.durationS))
      let samples = stride(from: 0, to: walk.durationS, by: 10).map { second -> String in
        let progress = Double(second) / Double(walk.durationS)
        let speed = 4.5 * min(progress * 12, 1) - 0.6 * sin(progress * .pi * 3).magnitude
        let ts = Self.wire(walk.startedAt.addingTimeInterval(Double(second)))
        let distance = Double(second) * walk.distanceM / Double(walk.durationS)
        return """
          {"ts":"\(ts)","belt_state":"active","speed_kmh":\(max(speed, 0.5)),\
          "distance_m":\(distance),"steps":\(second * 2)}
          """
      }
      let session = Self.sessionJSON(walk, end: Self.wire(end))
      let body = #"{"session":\#(session),"samples":[\#(samples.joined(separator: ","))]}"#
      return ["/sessions/\(walk.uuid)": .json(body)]
    }

    static let emptyRoutes: [String: SnapshotHost.Answer] = [
      "/sessions": .json(#"{"sessions":[]}"#),
      "/summary?period=week": .json(zeroSummary("week")),
      "/summary?period=month": .json(zeroSummary("month")),
      "/summary/days": .json(#"{"from":"2026-08-23","to":"2026-11-20","days":[]}"#),
    ]

    private static func zeroSummary(_ period: String) -> String {
      #"{"period":"\#(period)","sessions":0,"duration_s":0,"distance_m":0,"steps":0,"kcal":0}"#
    }
  }
#endif
