import Foundation
import Testing

@testable import PadKit

/// Reads from a running host, never writes: the belt is a physical machine, so no test sends
/// /start, /stop, /speed or /pref. Runs only with PADKIT_LIVE_URL set
/// (`make test-live` points it at http://127.0.0.1:7706 on the mini).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PADKIT_LIVE_URL"] != nil))
struct LiveHostTests {
  let client: PadClient

  init() throws {
    let raw = try #require(ProcessInfo.processInfo.environment["PADKIT_LIVE_URL"])
    client = PadClient(
      baseURL: try #require(URL(string: raw)),
      token: ProcessInfo.processInfo.environment["PADKIT_LIVE_TOKEN"])
  }

  @Test func decodesLiveStatus() async throws {
    let status = try await client.status()
    print("live /status: connected=\(status.connected) belt=\(status.beltState?.wire ?? "-")")
  }

  @Test func decodesLiveSessions() async throws {
    let sessions = try await client.sessions(limit: 3)
    #expect(sessions.count <= 3)
    print("live /sessions?limit=3: \(sessions.map(\.uuid))")
  }
}
