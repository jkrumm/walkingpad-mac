import Foundation
import Testing

@testable import PadKit

/// Every golden response decodes into its model, and encoding the model back gives the same
/// JSON: a renamed, added or removed field fails here, optional ones included.
@Suite struct ContractTests {
  /// The model each fixture decodes into, by file name.
  static var shapes: [String: any Codable.Type] {
    [
      "health": Health.self,
      "ok": Acknowledgement.self,
      "sync": SyncResult.self,
      "sessions": SessionList.self,
      "sessions-empty": SessionList.self,
      "session-detail": SessionDetail.self,
      "summary-all": Summary.self,
      "status-disconnected": Status.self,
      "status-stopped": Status.self,
      "status-starting": Status.self,
      "status-active": Status.self,
      "status-stopping": Status.self,
      "status-standby": Status.self,
      "status-unknown": Status.self,
      "status-current-session": Status.self,
      "error-bad-request": APIErrorBody.self,
      "error-not-found": APIErrorBody.self,
      "error-unavailable": APIErrorBody.self,
    ]
  }

  @Test func everyFixtureHasAModel() throws {
    #expect(try Fixtures.names() == Self.shapes.keys.sorted())
  }

  @Test(arguments: shapes.keys.sorted())
  func roundTrips(name: String) throws {
    let shape = try #require(Self.shapes[name])
    let original = try Fixtures.data(name)
    let model = try WireCoding.decoder().decode(shape, from: original)
    let encoded = try WireCoding.encoder().encode(model)
    #expect(try normalized(encoded) == normalized(original), "\(name) changed on a round trip")
  }

  @Test(arguments: [
    ("status-stopped", BeltState.stopped),
    ("status-starting", .starting),
    ("status-active", .active),
    ("status-stopping", .stopping),
    ("status-standby", .standby),
    ("status-unknown", .unknown("unknown(1)")),
  ])
  func beltStates(name: String, state: BeltState) throws {
    let status = try Fixtures.decode(Status.self, name)
    #expect(status.connected)
    #expect(status.beltState == state)
    #expect(ConnectionState(status: status) == .connected(state))
  }

  @Test func disconnectedStatusHasNoBeltFields() throws {
    let status = try Fixtures.decode(Status.self, "status-disconnected")
    #expect(!status.connected)
    #expect(status.beltState == nil && status.mode == nil && status.speedKmh == nil)
    #expect(ConnectionState(status: status) == .padDisconnected)
  }

  @Test func currentSessionDecodes() throws {
    let session = try #require(
      try Fixtures.decode(Status.self, "status-current-session").currentSession)
    #expect(session.durationS == 120)
    #expect(session.startedAt == Date(timeIntervalSince1970: 1_779_024_131))
  }

  @Test func sessionsCarryOpenAndSyncedState() throws {
    let sessions = try Fixtures.decode(SessionList.self, "sessions").sessions
    #expect(sessions.count == 3)
    #expect(sessions[0].endedAt == nil)
    #expect(sessions[1].syncedAt != nil)
    #expect(sessions[2].syncedAt == nil && sessions[2].endedAt != nil)
  }

  @Test func detailSamplesCoverEveryBeltState() throws {
    let states = try Fixtures.decode(SessionDetail.self, "session-detail").samples.map(\.beltState)
    #expect(
      Set(states.compactMap { $0?.wire })
        == ["starting", "active", "stopping", "stopped", "standby", "unknown(1)"])
  }

  @Test func goNanosecondInstantsParse() throws {
    let date = try #require(WireCoding.parseDate("2026-11-20T15:59:01.123456789Z"))
    #expect(abs(date.timeIntervalSince1970 - 1_795_190_341.123_457) < 0.001)
  }

  /// JSON as Foundation objects, with nulls dropped: Go writes an absent pointer as null,
  /// Swift's synthesized encoder leaves the key out.
  private func normalized(_ data: Data) throws -> NSObject {
    func strip(_ value: Any) -> Any {
      if let dict = value as? [String: Any] {
        return dict.filter { !($0.value is NSNull) }.mapValues(strip)
      }
      if let array = value as? [Any] { return array.map(strip) }
      return value
    }
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try #require(strip(object) as? NSObject)
  }
}
