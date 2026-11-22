import AppKit
import Foundation
import Testing

@testable import PadKit

@Suite struct PadFormatTests {
  let english = Locale(identifier: "en_US")

  @Test func distances() {
    #expect(PadFormat.distance(0, locale: english) == "0 m")
    #expect(PadFormat.distance(419.6, locale: english) == "420 m")
    #expect(PadFormat.distance(1240, locale: english) == "1.24 km")
  }

  @Test func durations() {
    #expect(PadFormat.duration(0) == "0:00")
    #expect(PadFormat.duration(245) == "4:05")
    #expect(PadFormat.duration(3723) == "1:02:03")
  }

  @Test func todayAddsTheOpenSession() throws {
    let status = try Fixtures.decode(Status.self, "status-current-session")
    let today = WalkTotals(today: status)
    #expect(today.durationS == status.today.durationS + 120)
    #expect(today.distanceM == status.today.distanceM + 70)
  }

  /// The title for one phase and choice of values, in English.
  private func title(
    _ phase: PadPhase, fixture: String, values: MenuBarValues, speed: Double = 3.5
  ) throws -> String? {
    let status = try Fixtures.decode(Status.self, fixture)
    return MenuBarContent(
      phase: phase, status: status, speed: speed, values: values, locale: english
    ).text
  }

  @Test func menuBarWhileWalkingShowsEverythingByDefault() throws {
    let status = try Fixtures.decode(Status.self, "status-current-session")
    let content = MenuBarContent(phase: .active, status: status, speed: 3.5, locale: english)
    #expect(
      content
        == MenuBarContent(symbol: "figure.walk", text: "3.5 km/h · 2:00 · 70 m · 110 steps"))
    #expect(
      try title(.active, fixture: "status-current-session", values: .all)
        == "3.5 km/h · 2:00 · 70 m · 110 steps")
  }

  @Test func menuBarWhileWalkingFollowsTheChosenValues() throws {
    let session = "status-current-session"
    #expect(try title(.active, fixture: session, values: .steps) == "110 steps")
    #expect(
      try title(.active, fixture: session, values: [.speed, .steps]) == "3.5 km/h · 110 steps")
    #expect(try title(.active, fixture: session, values: [.time, .distance]) == "2:00 · 70 m")
    #expect(try title(.active, fixture: session, values: []) == nil)
  }

  @Test func menuBarSpeedAloneShowsBeforeTheSessionAppears() throws {
    let status = try Fixtures.decode(Status.self, "status-standby")
    let title = { (values: MenuBarValues) in
      MenuBarContent(
        phase: .starting, status: status, speed: 0, values: values, locale: english
      ).text
    }
    #expect(title(.all) == "0.0 km/h")
    #expect(title([.time, .distance, .steps]) == nil)
  }

  @Test func menuBarWhenIdleShowsTodaysDistanceAndSteps() throws {
    let status = try Fixtures.decode(Status.self, "status-standby")
    let content = MenuBarContent(phase: .standby, status: status, speed: 0, locale: english)
    #expect(content == MenuBarContent(symbol: "figure.stand", text: "0 m · 0 steps"))
    #expect(try title(.standby, fixture: "status-standby", values: .steps) == "0 steps")
    #expect(try title(.standby, fixture: "status-standby", values: .distance) == "0 m")
    // Speed and time say nothing about a belt that stands.
    #expect(try title(.standby, fixture: "status-standby", values: [.speed, .time]) == nil)
    #expect(try title(.standby, fixture: "status-standby", values: []) == nil)
  }

  @Test func menuBarIdleAddsTheOpenSessionToToday() throws {
    // A pause between two walks: the host still holds the session, today's totals include it.
    let status = try Fixtures.decode(Status.self, "status-current-session")
    let steps = status.today.steps + 110
    #expect(
      try title(.standby, fixture: "status-current-session", values: .steps) == "\(steps) steps")
  }

  @Test func menuBarHasADistinctSymbolWithoutHostOrPad() {
    let unreachable = MenuBarContent(phase: .hostUnreachable("x"), status: nil, speed: 0)
    let disconnected = MenuBarContent(phase: .padDisconnected, status: nil, speed: 0)
    let idle = MenuBarContent(phase: .standby, status: nil, speed: 0)
    #expect(Set([unreachable.symbol, disconnected.symbol, idle.symbol]).count == 3)
    #expect(unreachable.text == nil && disconnected.text == nil)
  }

  @Test(arguments: MenuBarContent.allSymbols)
  func everySymbolExists(name: String) {
    #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
  }
}

@Suite struct SpeedRangeTests {
  @Test func presetsAreTheSpeedsTheOwnerWalks() {
    #expect(SpeedRange.presets == [3.0, 3.5, 4.0, 4.5, 5.0])
    #expect(SpeedRange.presets.allSatisfy { $0 == SpeedRange.clamp($0) })
  }

  @Test(arguments: [
    (3.0, 1, 3.5), (3.2, 1, 3.5), (3.0, -1, 2.5), (3.2, -1, 3.0), (5.8, 1, 6.0), (6.0, 1, 6.0),
    (0.5, -1, 0.5), (0, 1, 0.5), (4.5, 2, 5.5),
  ])
  func steps(from: Double, steps: Int, expected: Double) {
    #expect(SpeedRange.stepped(from: from, by: steps) == expected)
  }

  @Test func clampRoundsLikeTheHost() {
    #expect(SpeedRange.clamp(0.1) == 0.5)
    #expect(SpeedRange.clamp(7) == 6.0)
    #expect(SpeedRange.clamp(3.04) == 3.0)
  }
}

@Suite struct LoginItemStateTests {
  @Test func theToggleReadsOnWhenRegisteredOrAwaitingApproval() {
    #expect(LoginItemState.enabled.isOn)
    #expect(LoginItemState.requiresApproval.isOn)
    #expect(!LoginItemState.disabled.isOn)
    #expect(!LoginItemState.notFound.isOn)
  }

  @Test func everyStateThatIsNotPlainlyOnOrOffSaysWhy() {
    #expect(LoginItemState.enabled.note == nil)
    #expect(LoginItemState.disabled.note == nil)
    #expect(LoginItemState.requiresApproval.note?.contains("Login Items") == true)
    #expect(LoginItemState.notFound.note?.contains("Applications") == true)
  }
}

@Suite struct HostAddressTests {
  @Test(arguments: [
    ("http://127.0.0.1:7706", "http://127.0.0.1:7706"),
    ("  https://pad.example.ts.net/ ", "https://pad.example.ts.net"),
    ("127.0.0.1:7706", "http://127.0.0.1:7706"),
  ])
  func accepted(raw: String, expected: String) {
    #expect(HostAddress.parse(raw)?.absoluteString == expected)
  }

  @Test(arguments: ["", "   ", "ftp://example.com", "http://"])
  func rejected(raw: String) {
    #expect(HostAddress.parse(raw) == nil)
  }
}
