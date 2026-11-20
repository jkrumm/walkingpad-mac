import Foundation
import Testing

@testable import PadKit

/// Answers every request with one canned response and records what it was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [URLRequest] = []
  private let status: Int
  private let body: Data

  init(status: Int = 200, body: Data) {
    self.status = status
    self.body = body
  }

  var requests: [URLRequest] { lock.withLock { sent } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lock.withLock { sent.append(request) }
    let url = try #require(request.url)
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
    return (body, response)
  }
}

@Suite struct PadClientTests {
  let base = URL(string: "http://127.0.0.1:7706")!

  private func client(_ transport: FakeTransport, token: String? = nil) -> PadClient {
    PadClient(baseURL: base, token: token, transport: transport)
  }

  @Test func statusIsAGetWithTheBearerToken() async throws {
    let transport = FakeTransport(body: try Fixtures.data("status-active"))
    let status = try await client(transport, token: "fake-token").status()
    #expect(status.beltState == .active)
    let request = try #require(transport.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "http://127.0.0.1:7706/status")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    #expect(request.httpBody == nil)
  }

  @Test func noTokenSendsNoAuthorization() async throws {
    let transport = FakeTransport(body: try Fixtures.data("health"))
    _ = try await client(transport, token: "").health()
    #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func sessionsPassLimitAndBefore() async throws {
    let transport = FakeTransport(body: try Fixtures.data("sessions"))
    let before = Date(timeIntervalSince1970: 1_779_024_131)
    let sessions = try await client(transport).sessions(limit: 3, before: before)
    #expect(sessions.count == 3)
    #expect(
      transport.requests.first?.url?.absoluteString
        == "http://127.0.0.1:7706/sessions?limit=3&before=2026-05-17T13:22:11Z")
  }

  @Test func sessionDetailAndSummaryPaths() async throws {
    let detail = FakeTransport(body: try Fixtures.data("session-detail"))
    _ = try await client(detail).session(uuid: "abc")
    #expect(detail.requests.first?.url?.path() == "/sessions/abc")

    let summary = FakeTransport(body: try Fixtures.data("summary-all"))
    let totals = try await client(summary).summary(period: .all)
    #expect(totals.period == .all && totals.sessions == 2)
    #expect(summary.requests.first?.url?.query() == "period=all")
  }

  /// One write route: the call, the path it must hit and the JSON body it must send.
  struct WriteCase: Sendable {
    let path: String
    let body: String?
    let call: @Sendable (PadClient) async throws -> Void
  }

  @Test func writesPostTheSpeedBody() async throws {
    let cases = [
      WriteCase(path: "/start", body: #"{"speed_kmh":3.5}"#) { try await $0.start(speedKmh: 3.5) },
      WriteCase(path: "/start", body: nil) { try await $0.start() },
      WriteCase(path: "/stop", body: nil) { try await $0.stop() },
      WriteCase(path: "/speed", body: #"{"speed_kmh":4}"#) { try await $0.setSpeed(4) },
      WriteCase(path: "/pref/start-speed", body: #"{"speed_kmh":2}"#) {
        try await $0.setStartSpeed(2)
      },
    ]
    for write in cases {
      let transport = FakeTransport(body: try Fixtures.data("ok"))
      try await write.call(client(transport))
      let request = try #require(transport.requests.first)
      #expect(request.httpMethod == "POST")
      #expect(request.url?.path() == write.path)
      #expect(request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } == write.body)
    }
  }

  @Test func syncArgoReturnsCounts() async throws {
    let transport = FakeTransport(body: try Fixtures.data("sync"))
    #expect(try await client(transport).syncArgo() == SyncResult(synced: 2, failed: 1))
  }

  @Test(arguments: [
    ("error-bad-request", 400, "limit must be a positive integer"),
    ("error-not-found", 404, "session not found"),
    ("error-unavailable", 503, "ble controller not connected"),
  ])
  func errorBodiesBecomePadErrors(name: String, status: Int, message: String) async throws {
    let transport = FakeTransport(status: status, body: try Fixtures.data(name))
    await #expect(throws: PadError.http(status: status, message: message)) {
      _ = try await client(transport).session(uuid: "missing")
    }
  }

  @Test func errorWithoutABodyKeepsTheStatus() async throws {
    let transport = FakeTransport(status: 502, body: Data("bad gateway".utf8))
    await #expect(throws: PadError.http(status: 502, message: nil)) {
      _ = try await client(transport).status()
    }
  }

  /// A poll gives up early; a write outlives the host's wait for the ramp (about five seconds).
  @Test func readsTimeOutEarlyAndWritesOutliveTheRamp() async throws {
    let read = FakeTransport(body: try Fixtures.data("status-standby"))
    _ = try await client(read).status()
    #expect(read.requests.first?.timeoutInterval == PadClient.readTimeout)

    let write = FakeTransport(body: try Fixtures.data("ok"))
    try await client(write).start(speedKmh: 3)
    let timeout = try #require(write.requests.first?.timeoutInterval)
    #expect(timeout >= 15)
  }
}
