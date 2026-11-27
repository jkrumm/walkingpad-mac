import Foundation
import Synchronization
import Testing

@testable import PadKit

/// A host that answers by path from the golden files and records every request.
final class HistoryHost: HTTPTransport, Sendable {
  private struct State {
    var routes: [String: String] = [:]
    var failure: URLError.Code?
    var requests: [String] = []
  }

  private let state = Mutex(State())

  init(_ routes: [String: String]) { state.withLock { $0.routes = routes } }

  var requests: [String] { state.withLock { $0.requests } }
  func fail(_ code: URLError.Code) { state.withLock { $0.failure = code } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    let path = url.path(percentEncoded: false)
    let (failure, fixture) = state.withLock { state in
      state.requests.append(path + (url.query().map { "?" + $0 } ?? ""))
      return (state.failure, state.routes[path])
    }
    if let failure { throw URLError(failure) }
    let name = try #require(fixture, "no route for \(path)")
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
    return (try Fixtures.data(name), response)
  }
}

enum HistoryClock {
  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }()
  /// 2026-05-19 12:00 UTC.
  static let now = Date(timeIntervalSince1970: 1_779_192_000)
}

@Suite @MainActor struct HistoryStoreTests {
  static let base = URL(string: "http://127.0.0.1:7706")!
  static let utc = HistoryClock.utc
  static let now = HistoryClock.now

  static let populated = [
    "/sessions": "sessions", "/summary": "summary-all", "/summary/days": "summary-days",
  ]
  static let empty = [
    "/sessions": "sessions-empty", "/summary": "summary-all", "/summary/days": "summary-days-empty",
  ]

  private func store(_ host: HistoryHost, pageSize: Int = 50) -> HistoryStore {
    let client = PadClient(baseURL: Self.base, transport: host)
    return HistoryStore(
      client: { client }, calendar: Self.utc, pageSize: pageSize, now: { HistoryClock.now })
  }

  @Test func reloadLoadsTotalsDaysAndSessions() async {
    let host = HistoryHost(Self.populated)
    let history = store(host)
    await history.reload()
    #expect(history.load == .loaded)
    #expect(history.week != nil && history.month != nil)
    #expect(history.days.count == 4)
    #expect(history.sessions.count == 3)
    #expect(history.range == .days30)
  }

  @Test func reloadAsksForTheLast90DaysEndingToday() async {
    let host = HistoryHost(Self.populated)
    await store(host).reload()
    let requests = host.requests
    #expect(requests.contains("/summary?period=week"))
    #expect(requests.contains("/summary?period=month"))
    #expect(requests.contains("/summary/days?from=2026-02-19&to=2026-05-19"))
    #expect(requests.contains("/sessions?limit=50"))
  }

  @Test func openSessionsAreNotListed() async {
    let host = HistoryHost(Self.populated)
    let history = store(host)
    await history.reload()
    let days = history.groupedSessions
    #expect(days.map(\.sessions.count) == [1, 1])
    #expect(days.flatMap(\.sessions).allSatisfy { $0.endedAt != nil })
  }

  @Test func noSessionsIsALoadedEmptyState() async {
    let host = HistoryHost(Self.empty)
    let history = store(host)
    await history.reload()
    #expect(history.load == .loaded)
    #expect(history.sessions.isEmpty && history.groupedSessions.isEmpty)
    #expect(history.isEmpty(.days30) && history.isEmpty(.days90))
    #expect(!history.canLoadMore)
  }

  @Test func anUnreachableHostFailsWithTheReasonAndClearsTheData() async {
    let host = HistoryHost(Self.populated)
    let history = store(host)
    await history.reload()
    host.fail(.cannotConnectToHost)
    await history.reload()
    #expect(history.load == .failed("Connection refused"))
    #expect(history.sessions.isEmpty && history.days.isEmpty && history.week == nil)
  }

  @Test func noHostIsAFailureThatPointsToSettings() async {
    let history = HistoryStore(client: { nil }, calendar: Self.utc, now: { HistoryClock.now })
    await history.reload()
    guard case .failed(let reason) = history.load else {
      Issue.record("expected a failure")
      return
    }
    #expect(reason.contains("Settings"))
  }

  @Test func barsCoverTheRangeAndFlagEmptyDays() async throws {
    let host = HistoryHost(Self.populated)
    let history = store(host)
    await history.reload()
    let bars = history.bars(.days30)
    #expect(bars.map(\.distanceM) == [0, 942, 2100.5, 0])
    #expect(bars.first?.date == HistoryDates.date("2026-05-16", calendar: Self.utc))
    #expect(!history.isEmpty(.days30))
  }

  @Test func daysAgoCountsFromTheStoreClock() throws {
    let day = try #require(HistoryDates.date("2026-05-17", calendar: Self.utc))
    #expect(store(HistoryHost(Self.populated)).daysAgo(day) == 2)
  }

  @Test func loadMoreAppendsOlderSessionsWithoutDuplicates() async {
    let host = HistoryHost(Self.populated)
    let history = store(host, pageSize: 3)
    await history.reload()
    #expect(history.canLoadMore)
    await history.loadMore()
    // The fixture answers the same three sessions again: nothing new, so paging stops.
    #expect(history.sessions.count == 3)
    #expect(!history.canLoadMore)
    #expect(
      host.requests.contains { $0.hasPrefix("/sessions?limit=3&before=2026-05-17T13:22:11Z") })
  }

  @Test func aShortPageEndsPaging() async {
    let host = HistoryHost(Self.populated)
    let history = store(host, pageSize: 50)
    await history.reload()
    #expect(!history.canLoadMore)
  }

  @Test func detailReadsOneSession() async throws {
    let host = HistoryHost(["/sessions/0d9e8f7a-6b5c-4d3e-9f21-0a1b2c3d4e5f": "session-detail"])
    let detail = try await store(host).detail(uuid: "0d9e8f7a-6b5c-4d3e-9f21-0a1b2c3d4e5f")
    #expect(detail.session.durationS == 754)
    #expect(detail.samples.count == 8)
  }
}

@Suite struct HistoryDatesTests {
  static let utc = HistoryClock.utc

  @Test(arguments: [
    (30, "2026-04-20", "2026-05-19"),
    (90, "2026-02-19", "2026-05-19"),
    (1, "2026-05-19", "2026-05-19"),
  ])
  func windowEndsToday(days: Int, from: String, to: String) {
    let window = HistoryDates.window(days: days, now: HistoryClock.now, calendar: Self.utc)
    #expect(window.from == from && window.to == to)
  }

  @Test(arguments: [("2026-05-19", 0), ("2026-05-18", 1), ("2026-05-17", 2), ("2026-04-19", 30)])
  func daysAgoCountsCalendarDays(day: String, ago: Int) throws {
    let date = try #require(HistoryDates.date(day, calendar: Self.utc))
    #expect(HistoryDates.daysAgo(date, now: HistoryClock.now, calendar: Self.utc) == ago)
  }

  @Test func datesRoundTrip() throws {
    let date = try #require(HistoryDates.date("2026-05-17", calendar: Self.utc))
    #expect(HistoryDates.string(date, calendar: Self.utc) == "2026-05-17")
    #expect(HistoryDates.date("yesterday", calendar: Self.utc) == nil)
  }

  private func session(_ id: String, start: String, end: String?) throws -> Session {
    let json = """
      {"uuid":"\(id)","started_at":"\(start)","ended_at":\(end.map { "\"\($0)\"" } ?? "null"),\
      "duration_s":600,"distance_m":1000,"steps":1500,"avg_speed_kmh":4,"max_speed_kmh":5,\
      "kcal":50,"pause_count":0,"synced_at":null}
      """
    return try WireCoding.decoder().decode(Session.self, from: Data(json.utf8))
  }

  @Test func aWalkAcrossMidnightStaysOnItsStartDay() throws {
    let night = try session("night", start: "2026-05-17T23:50:00Z", end: "2026-05-18T00:20:00Z")
    let morning = try session("morning", start: "2026-05-18T07:00:00Z", end: "2026-05-18T07:10:00Z")
    // Newest first, as the host lists them.
    let days = SessionGrouping.byDay([morning, night], calendar: Self.utc)
    #expect(days.count == 2)
    #expect(days[0].sessions.map(\.uuid) == ["morning"])
    #expect(days[1].sessions.map(\.uuid) == ["night"])
    #expect(days[1].day == HistoryDates.date("2026-05-17", calendar: Self.utc))
  }

  @Test func daysSumTheirSessions() throws {
    let first = try session("a", start: "2026-05-18T09:00:00Z", end: "2026-05-18T09:10:00Z")
    let second = try session("b", start: "2026-05-18T08:00:00Z", end: "2026-05-18T08:10:00Z")
    let day = try #require(SessionGrouping.byDay([first, second], calendar: Self.utc).first)
    #expect(day.totals == WalkTotals(durationS: 1200, distanceM: 2000, steps: 3000, kcal: 100))
  }

  @Test func downsamplingKeepsTheEndsAndTheBudget() throws {
    let samples = (0..<1000).map { second in
      Sample(
        ts: Date(timeIntervalSince1970: Double(second)), beltState: nil, speedKmh: Double(second),
        distanceM: 0, steps: 0)
    }
    let reduced = SampleSeries.downsample(samples, maxPoints: 100)
    #expect(reduced.count == 100)
    #expect(reduced.first == samples.first && reduced.last == samples.last)
    #expect(SampleSeries.downsample(Array(samples.prefix(50)), maxPoints: 100).count == 50)
  }
}
