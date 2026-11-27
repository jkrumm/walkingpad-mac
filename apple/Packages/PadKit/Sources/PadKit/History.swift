import Foundation
import Observation

/// How far back the History chart looks.
public enum HistoryRange: Int, CaseIterable, Identifiable, Sendable {
  case days30 = 30
  case days90 = 90

  public var id: Int { rawValue }
  public var days: Int { rawValue }
  public var title: String { "\(rawValue) days" }
}

/// Calendar days as the host writes them ("2026-05-17"). The host buckets a session into the day
/// it started in its own time zone; the app asks for days by the Mac's calendar, which is the same
/// zone whenever the host is the user's own Mac or the mini.
public enum HistoryDates {
  public static func string(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  public static func date(_ string: String, calendar: Calendar) -> Date? {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  /// Whole calendar days from `day` to `now`: 0 today, 1 yesterday, negative for a future day.
  public static func daysAgo(_ day: Date, now: Date, calendar: Calendar) -> Int {
    let from = calendar.startOfDay(for: day)
    let to = calendar.startOfDay(for: now)
    return calendar.dateComponents([.day], from: from, to: to).day ?? 0
  }

  /// The `days` days ending today, today included.
  public static func window(days: Int, now: Date, calendar: Calendar) -> (from: String, to: String)
  {
    let first = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: now) ?? now
    return (string(first, calendar: calendar), string(now, calendar: calendar))
  }
}

/// One bar of the distance chart.
public struct ChartBar: Equatable, Identifiable, Sendable {
  public let date: Date
  public let distanceM: Double
  public var id: Date { date }
}

/// The closed sessions of one calendar day, newest first.
public struct SessionDay: Equatable, Identifiable, Sendable {
  public let day: Date
  public let sessions: [Session]
  public var id: Date { day }

  public var totals: WalkTotals {
    WalkTotals(
      durationS: sessions.reduce(0) { $0 + $1.durationS },
      distanceM: sessions.reduce(0) { $0 + $1.distanceM },
      steps: sessions.reduce(0) { $0 + $1.steps }, kcal: sessions.reduce(0) { $0 + $1.kcal })
  }
}

public enum SessionGrouping {
  /// Groups sessions by the day they started, keeping their order (newest first). A walk that
  /// crosses midnight stays on its start day, as in the host's per-day totals. A session still
  /// open is left out: the popover shows the walk in progress.
  public static func byDay(_ sessions: [Session], calendar: Calendar) -> [SessionDay] {
    var days: [SessionDay] = []
    for session in sessions where session.endedAt != nil {
      let day = calendar.startOfDay(for: session.startedAt)
      if let last = days.last, last.day == day {
        days[days.count - 1] = SessionDay(day: day, sessions: last.sessions + [session])
      } else {
        days.append(SessionDay(day: day, sessions: [session]))
      }
    }
    return days
  }
}

public enum SampleSeries {
  /// At most `maxPoints` samples spread evenly over the series, first and last kept: a long walk
  /// has one sample a second and a chart needs a few hundred.
  public static func downsample(_ samples: [Sample], maxPoints: Int) -> [Sample] {
    guard maxPoints > 1, samples.count > maxPoints else { return samples }
    let step = Double(samples.count - 1) / Double(maxPoints - 1)
    return (0..<maxPoints).map { samples[Int((Double($0) * step).rounded())] }
  }
}

/// What the History window shows: this week's and month's totals, a distance per day, and the
/// stored sessions. It reads the host through the client the main store polls; it never writes.
@MainActor
@Observable
public final class HistoryStore {
  public enum Load: Equatable, Sendable {
    case idle
    case loading
    case loaded
    /// The reason, as one line.
    case failed(String)
  }

  public private(set) var load: Load = .idle
  public private(set) var week: Summary?
  public private(set) var month: Summary?
  /// One entry per day of the longest chart range, oldest first.
  public private(set) var days: [DaySummary] = []
  /// Newest first, open sessions included; `SessionGrouping` leaves them out.
  public private(set) var sessions: [Session] = []
  public private(set) var canLoadMore = false
  public private(set) var isLoadingMore = false
  public private(set) var moreError: String?
  public var range: HistoryRange = .days30

  @ObservationIgnored private let client: @MainActor () -> PadClient?
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private let pageSize: Int
  @ObservationIgnored private var generation = 0

  public init(
    client: @escaping @MainActor () -> PadClient?, calendar: Calendar = .current,
    pageSize: Int = 50, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.client = client
    self.calendar = calendar
    self.pageSize = pageSize
    self.now = now
  }

  /// The bars of `range`, one per day, days without a walk at 0.
  public func bars(_ range: HistoryRange) -> [ChartBar] {
    days.suffix(range.days).compactMap { day in
      HistoryDates.date(day.date, calendar: calendar).map {
        ChartBar(date: $0, distanceM: day.distanceM)
      }
    }
  }

  /// True when no walk lies in `range`.
  public func isEmpty(_ range: HistoryRange) -> Bool {
    !days.suffix(range.days).contains { $0.sessions > 0 }
  }

  public var groupedSessions: [SessionDay] { SessionGrouping.byDay(sessions, calendar: calendar) }

  /// Whole calendar days from `day` to the store's today, the day its window ends on.
  public func daysAgo(_ day: Date) -> Int {
    HistoryDates.daysAgo(day, now: now(), calendar: calendar)
  }

  /// Loads everything again; the data on screen stays until the new answers are in.
  public func reload() async {
    guard let client = client() else {
      clear()
      load = .failed("No host is set. Enter its URL in Settings.")
      return
    }
    generation += 1
    let asked = generation
    load = .loading
    let window = HistoryDates.window(
      days: HistoryRange.allCases.map(\.days).max() ?? 90, now: now(), calendar: calendar)
    let limit = pageSize
    do {
      async let week = client.summary(period: .week)
      async let month = client.summary(period: .month)
      async let days = client.summaryDays(from: window.from, to: window.to)
      async let sessions = client.sessions(limit: limit)
      let answers = try await (week, month, days, sessions)
      guard asked == generation else { return }
      self.week = answers.0
      self.month = answers.1
      self.days = answers.2.days
      self.sessions = answers.3
      canLoadMore = answers.3.count == limit
      moreError = nil
      load = .loaded
    } catch {
      guard asked == generation, !PadPhase.isCancellation(error) else { return }
      clear()
      load = .failed(PadPhase.describe(error))
    }
  }

  /// The next page of older sessions.
  public func loadMore() async {
    guard canLoadMore, !isLoadingMore, let client = client(), let last = sessions.last else {
      return
    }
    isLoadingMore = true
    moreError = nil
    let asked = generation
    defer { isLoadingMore = false }
    do {
      let page = try await client.sessions(limit: pageSize, before: last.startedAt)
      guard asked == generation else { return }
      // The cursor is written to the millisecond while the host stores nanoseconds, so the last
      // session can come back once more.
      let known = Set(sessions.map(\.uuid))
      let fresh = page.filter { !known.contains($0.uuid) }
      sessions += fresh
      canLoadMore = !fresh.isEmpty && page.count == pageSize
    } catch {
      guard asked == generation, !PadPhase.isCancellation(error) else { return }
      moreError = PadPhase.describe(error)
    }
  }

  /// A session with its samples, for the detail view.
  public func detail(uuid: String) async throws -> SessionDetail {
    guard let client = client() else { throw PadError.notConfigured }
    return try await client.session(uuid: uuid)
  }

  private func clear() {
    week = nil
    month = nil
    days = []
    sessions = []
    canLoadMore = false
    moreError = nil
  }
}
