import Foundation
import Synchronization
import Testing

@testable import PadKit

/// A host behind a fake transport: `/status` answers the current fixture (or fails), every write
/// answers `{"ok":true}` and is recorded. A write can be held open to see the store while it waits.
final class ScriptedHost: HTTPTransport, Sendable {
  enum Answer: Sendable {
    case fixture(String)
    case failure(status: Int, body: String)
    case transport(URLError.Code)
  }

  private struct State {
    var status: Answer = .fixture("status-standby")
    var writes: [(path: String, body: String?)] = []
    var holds: [CheckedContinuation<Void, Never>] = []
    var holdWrites = false
    var holdStatus = false
    var statusHolds: [CheckedContinuation<Void, Never>] = []
    var statusReads = 0
    var writeAnswer: Answer = .fixture("ok")
  }

  private let state = Mutex(State())

  func answer(_ status: Answer) { state.withLock { $0.status = status } }
  func answerWrites(_ answer: Answer) { state.withLock { $0.writeAnswer = answer } }
  var writes: [String] { state.withLock { $0.writes.map(\.path) } }
  var writeBodies: [String?] { state.withLock { $0.writes.map(\.body) } }
  var heldWrites: Int { state.withLock { $0.holds.count } }
  var heldStatus: Int { state.withLock { $0.statusHolds.count } }
  var statusReads: Int { state.withLock { $0.statusReads } }

  /// `/status` waits until `release()`.
  func holdStatus() { state.withLock { $0.holdStatus = true } }

  /// Writes wait until `release()`.
  func holdWrites() { state.withLock { $0.holdWrites = true } }

  func release() {
    let holds = state.withLock { state in
      state.holdWrites = false
      state.holdStatus = false
      defer {
        state.holds = []
        state.statusHolds = []
      }
      return state.holds + state.statusHolds
    }
    for hold in holds { hold.resume() }
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    let answer: Answer
    if request.httpMethod == "GET" {
      let hold = state.withLock { state in
        state.statusReads += 1
        return state.holdStatus
      }
      if hold {
        await withCheckedContinuation { continuation in
          state.withLock { $0.statusHolds.append(continuation) }
        }
      }
      answer = state.withLock { $0.status }
    } else {
      let body = request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) }
      let (hold, written) = state.withLock { state in
        state.writes.append((url.path(), body))
        return (state.holdWrites, state.writeAnswer)
      }
      if hold {
        await withCheckedContinuation { continuation in
          state.withLock { $0.holds.append(continuation) }
        }
      }
      answer = written
    }
    switch answer {
    case .fixture(let name):
      return (try Fixtures.data(name), try Self.response(url, 200))
    case .failure(let status, let body):
      return (Data(body.utf8), try Self.response(url, status))
    case .transport(let code):
      throw URLError(code)
    }
  }

  private static func response(_ url: URL, _ status: Int) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
  }
}

/// Records every wait of the poll loop and parks the loop after `limit` waits.
final class RecordingSleeper: Sendable {
  private let recorded = Mutex<[Duration]>([])
  let limit: Int

  init(limit: Int) { self.limit = limit }

  var durations: [Duration] { recorded.withLock { $0 } }

  func sleep(_ duration: Duration) async throws {
    let count = recorded.withLock { list in
      list.append(duration)
      return list.count
    }
    if count >= limit { try await Task.sleep(for: .seconds(3600)) }
  }
}

@MainActor
@Suite struct PadStoreTests {
  let host = ScriptedHost()
  let base = URL(string: "http://127.0.0.1:7706")

  private func store(sleeper: RecordingSleeper? = nil) throws -> PadStore {
    let client = PadClient(baseURL: try #require(base), transport: host)
    guard let sleeper else { return PadStore(client: client) }
    return PadStore(client: client, sleep: { try await sleeper.sleep($0) })
  }

  /// Lets the store's tasks run until `done` holds.
  private func settle(_ done: () -> Bool) async {
    for _ in 0..<10_000 where !done() { await Task.yield() }
  }

  @Test func noHostIsUnconfiguredAndNotPolled() async {
    let store = PadStore(client: nil)
    await store.refresh()
    #expect(store.phase == .unconfigured)
    #expect(store.pollInterval == nil)
  }

  @Test func aHostStartsAsConnecting() throws {
    #expect(try store().phase == .connecting)
  }

  @Test(arguments: [
    (ScriptedHost.Answer.fixture("status-standby"), PadPhase.standby, true),
    (.fixture("status-active"), .active, true),
    (.fixture("status-disconnected"), .padDisconnected, true),
    (
      .failure(status: 401, body: #"{"error":"missing or bad bearer token"}"#), .unauthorized, false
    ),
    (.transport(.timedOut), .hostUnreachable("Timed out"), false),
  ])
  func refreshMapsTheAnswer(answer: ScriptedHost.Answer, phase: PadPhase, hasStatus: Bool)
    async throws
  {
    let store = try store()
    host.answer(answer)
    await store.refresh()
    #expect(store.phase == phase)
    #expect((store.status != nil) == hasStatus)
  }

  @Test func theLoopPollsFastWhileWalkingAndSlowWhenIdle() async throws {
    let sleeper = RecordingSleeper(limit: 1)
    let store = try store(sleeper: sleeper)
    host.answer(.fixture("status-standby"))
    let loop = Task { await store.run() }
    defer { loop.cancel() }

    await settle { sleeper.durations.count == 1 }
    #expect(sleeper.durations == [PollingPolicy.slow])

    host.answer(.fixture("status-active"))
    let walking = RecordingSleeper(limit: 1)
    let fast = try self.store(sleeper: walking)
    let second = Task { await fast.run() }
    defer { second.cancel() }
    await settle { walking.durations.count == 1 }
    #expect(walking.durations == [PollingPolicy.fast])
  }

  @Test func openingThePopoverCutsTheSlowWaitAndPollsFast() async throws {
    let sleeper = RecordingSleeper(limit: 2)
    let store = try store(sleeper: sleeper)
    let loop = Task { await store.run() }
    defer { loop.cancel() }

    await settle { sleeper.durations.count == 1 }
    #expect(store.pollInterval == PollingPolicy.slow)
    store.setPopoverOpen(true)
    #expect(store.pollInterval == PollingPolicy.fast)
    await settle { sleeper.durations.count == 2 }
    #expect(sleeper.durations == [PollingPolicy.slow, PollingPolicy.fast])

    store.setPopoverOpen(false)
    #expect(store.pollInterval == PollingPolicy.slow)
  }

  @Test func anOpenSessionPollsFast() async throws {
    let store = try store()
    host.answer(.fixture("status-current-session"))
    await store.refresh()
    #expect(store.phase == .standby)
    #expect(store.pollInterval == PollingPolicy.fast)
  }

  @Test func startSendsTheStartSpeedAndHoldsTheControlsUntilTheHostAnswers() async throws {
    let store = try store()
    store.startSpeed = 3.5
    await store.refresh()
    #expect(store.canStart)

    host.holdWrites()
    let start = Task { await store.start() }
    await settle { host.heldWrites == 1 }
    #expect(store.command == .start)
    #expect(!store.canStart && !store.canStop && !store.canChangeSpeed)

    host.answer(.fixture("status-active"))
    host.release()
    await start.value
    #expect(store.command == nil)
    #expect(store.phase == .active)
    #expect(host.writes == ["/start"])
    #expect(host.writeBodies == [#"{"speed_kmh":3.5}"#])
  }

  @Test func toggleStopsAMovingBeltAndStartsAStandingOne() async throws {
    let store = try store()
    host.answer(.fixture("status-active"))
    await store.refresh()
    await store.toggle()
    host.answer(.fixture("status-standby"))
    await store.refresh()
    await store.toggle()
    #expect(host.writes == ["/stop", "/start"])
  }

  @Test func speedStepsOnlyWhileWalkingAndStayInRange() async throws {
    let store = try store()
    await store.refresh()
    await store.changeSpeed(by: 1)
    #expect(host.writes.isEmpty, "/speed on a standing belt would start it")

    host.answer(.fixture("status-active"))  // 4.5 km/h
    await store.refresh()
    await store.changeSpeed(by: 1)
    #expect(store.speedTarget == 5.0)
    await store.changeSpeed(by: 4)
    #expect(store.speedTarget == 6.0)
    #expect(host.writeBodies == [#"{"speed_kmh":5}"#, #"{"speed_kmh":6}"#])
  }

  @Test func speedPressesDuringASendEndAtTheLastOne() async throws {
    let store = try store()
    host.answer(.fixture("status-active"))
    await store.refresh()
    host.holdWrites()
    let first = Task { await store.changeSpeed(by: 1) }
    await settle { host.heldWrites == 1 }
    await store.changeSpeed(by: 1)
    await store.changeSpeed(by: 1)
    #expect(store.displayedSpeed == 6.0)
    host.release()
    await first.value
    #expect(host.writeBodies == [#"{"speed_kmh":5}"#, #"{"speed_kmh":6}"#])
  }

  @Test func aQueuedSpeedIsDroppedWhenTheBeltStoppedMeanwhile() async throws {
    let store = try store()
    host.answer(.fixture("status-active"))
    await store.refresh()
    host.holdWrites()
    let first = Task { await store.changeSpeed(by: 1) }
    await settle { host.heldWrites == 1 }
    await store.changeSpeed(by: 1)
    host.answer(.fixture("status-stopped"))  // the pad's remote stopped the belt
    host.release()
    await first.value
    #expect(host.writeBodies == [#"{"speed_kmh":5}"#], "/speed would start the stopped belt")
    #expect(store.phase == .standby && store.command == nil)
  }

  @Test func aWakeDuringAPollIsNotLost() async throws {
    let sleeper = RecordingSleeper(limit: 1)
    let store = try store(sleeper: sleeper)
    host.holdStatus()
    let loop = Task { await store.run() }
    defer { loop.cancel() }
    await settle { host.heldStatus == 1 }
    store.setPopoverOpen(true)
    host.release()
    await settle { sleeper.durations.count == 1 }
    #expect(host.statusReads == 2, "the wake polls again at once instead of waiting")
    #expect(sleeper.durations == [PollingPolicy.fast])
  }

  @Test func aFailedCommandIsReported() async throws {
    let store = try store()
    await store.refresh()
    host.answerWrites(.failure(status: 503, body: #"{"error":"ble controller not connected"}"#))
    await store.start()
    #expect(store.commandError == "HTTP 503: ble controller not connected")
    #expect(store.command == nil)
    #expect(store.phase == .standby)
  }

  @Test func configureDropsTheOldHostAndPollsTheNewOne() async throws {
    let store = try store()
    await store.refresh()
    #expect(store.status != nil)
    store.configure(nil)
    #expect(store.phase == .unconfigured && store.status == nil)

    let other = ScriptedHost()
    other.answer(.fixture("status-active"))
    store.configure(PadClient(baseURL: try #require(base), transport: other))
    #expect(store.phase == .connecting)
    await store.refresh()
    #expect(store.phase == .active)
  }

  @Test func anAnswerFromAReplacedHostIsDropped() async throws {
    let store = try store()
    host.holdStatus()
    let stale = Task { await store.refresh() }
    await settle { host.heldStatus == 1 }
    store.configure(nil)
    host.release()
    await stale.value
    #expect(store.phase == .unconfigured && store.status == nil)
  }
}
