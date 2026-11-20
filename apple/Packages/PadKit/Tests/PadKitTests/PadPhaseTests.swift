import Foundation
import Testing

@testable import PadKit

@Suite struct PadPhaseTests {
  @Test(arguments: [
    ("status-standby", PadPhase.standby),
    ("status-stopped", .standby),
    ("status-unknown", .standby),
    ("status-current-session", .standby),
    ("status-starting", .starting),
    ("status-active", .active),
    ("status-stopping", .stopping),
    ("status-disconnected", .padDisconnected),
  ])
  func everyFixtureStatusMapsToOnePhase(name: String, phase: PadPhase) throws {
    let status = try Fixtures.decode(Status.self, name)
    #expect(PadPhase(status: status) == phase)
  }

  @Test func connectedWithoutAFrameYetIsStandby() throws {
    let status = try Fixtures.decode(Status.self, "status-disconnected")
    let connected = Status(
      connected: true, beltState: nil, mode: nil, speedKmh: nil, observedAt: nil,
      currentSession: nil, today: status.today, device: status.device)
    #expect(PadPhase(status: connected) == .standby)
  }

  @Test func a401IsUnauthorized() {
    let error = PadError.http(status: 401, message: "missing or bad bearer token")
    #expect(PadPhase(error: error) == .unauthorized)
  }

  @Test(arguments: [
    (
      PadError.http(status: 503, message: "ble controller not connected") as any Error,
      "HTTP 503: ble controller not connected"
    ),
    (PadError.http(status: 502, message: nil), "HTTP 502"),
    (URLError(.timedOut), "Timed out"),
    (URLError(.cannotConnectToHost), "Connection refused"),
    (URLError(.cannotFindHost), "Host not found"),
  ])
  func otherFailuresAreAnUnreachableHost(error: any Error, reason: String) {
    #expect(PadPhase(error: error) == .hostUnreachable(reason))
  }

  @Test func cancellationIsNotAFailure() {
    #expect(PadPhase.isCancellation(CancellationError()))
    #expect(PadPhase.isCancellation(URLError(.cancelled)))
    #expect(!PadPhase.isCancellation(URLError(.timedOut)))
  }

  @Test func onlyTheBeltStatesMove() {
    let moving = [PadPhase.starting, .active, .stopping]
    let still: [PadPhase] = [
      .unconfigured, .connecting, .hostUnreachable("x"), .unauthorized, .padDisconnected,
      .standby,
    ]
    let movingCount = moving.filter { $0.isMoving }.count
    let stillCount = still.filter { $0.isMoving }.count
    #expect(movingCount == moving.count)
    #expect(stillCount == 0)
  }
}

@Suite struct PollingPolicyTests {
  @Test(arguments: [
    (PadPhase.unconfigured, false, false, Duration?.none),
    (.connecting, false, false, PollingPolicy.slow),
    (.hostUnreachable("x"), false, false, PollingPolicy.slow),
    (.unauthorized, false, false, PollingPolicy.slow),
    (.padDisconnected, false, false, PollingPolicy.slow),
    (.standby, false, false, PollingPolicy.slow),
    (.standby, true, false, PollingPolicy.fast),
    (.standby, false, true, PollingPolicy.fast),
    (.hostUnreachable("x"), false, true, PollingPolicy.fast),
    (.starting, false, false, PollingPolicy.fast),
    (.active, false, false, PollingPolicy.fast),
    (.stopping, false, false, PollingPolicy.fast),
    (.unconfigured, false, true, Duration?.none),
  ])
  func interval(phase: PadPhase, sessionOpen: Bool, popoverOpen: Bool, expected: Duration?) {
    #expect(
      PollingPolicy.interval(phase: phase, sessionOpen: sessionOpen, popoverOpen: popoverOpen)
        == expected)
  }

  @Test func fastIsOneSecondAndSlowTen() {
    #expect(PollingPolicy.fast == .seconds(1))
    #expect(PollingPolicy.slow == .seconds(10))
  }
}
