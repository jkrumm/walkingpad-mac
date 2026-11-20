import Foundation
import Observation

/// A belt command the popover or a hotkey sent. One runs at a time.
public enum PadCommand: Equatable, Sendable {
  case start, stop, speed
}

/// The app's one source of truth about the host: polls `GET /status` (`PollingPolicy`), maps
/// every answer to a `PadPhase` and sends the belt commands. The views and the hotkeys only read
/// it and call its methods.
@MainActor
@Observable
public final class PadStore {
  /// Waits for a duration; `Task.sleep` in the app, a recorder in tests.
  public typealias Sleeper = @Sendable (Duration) async throws -> Void

  public private(set) var phase: PadPhase
  /// The last `/status` answer; nil while the host does not answer.
  public private(set) var status: Status?
  /// The command in flight. `/start` blocks about five seconds while the belt ramps.
  public private(set) var command: PadCommand?
  /// Why the last command failed; cleared by the next one.
  public private(set) var commandError: String?
  /// The speed last asked for, shown until the belt reports it.
  public private(set) var speedTarget: Double?
  /// The speed `start()` asks for when it is given none.
  public var startSpeed: Double
  public private(set) var isPopoverOpen = false

  @ObservationIgnored private var client: PadClient?
  @ObservationIgnored private let sleep: Sleeper
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private var nap: Task<Void, Never>?
  @ObservationIgnored private var speedTargetSetAt: Date?
  /// Bumped by `configure`, so an answer from the replaced host is dropped.
  @ObservationIgnored private var generation = 0

  /// How long a requested speed is shown when the belt does not report it.
  static let speedTargetHold: TimeInterval = 5

  public init(
    client: PadClient?, startSpeed: Double = SpeedRange.defaultStartSpeed,
    sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.client = client
    self.startSpeed = startSpeed
    self.sleep = sleep
    self.now = now
    phase = client == nil ? .unconfigured : .connecting
  }

  // MARK: - Polling

  /// The wait before the next poll; nil while there is no host.
  public var pollInterval: Duration? {
    PollingPolicy.interval(
      phase: phase, sessionOpen: status?.currentSession != nil, popoverOpen: isPopoverOpen)
  }

  /// Polls until the calling task is cancelled. A change that wants an earlier answer (a new host,
  /// the popover opening) cuts the current wait short.
  public func run() async {
    while !Task.isCancelled {
      await refresh()
      await pause(pollInterval ?? .seconds(3600))
    }
  }

  /// Asks `/status` once.
  public func refresh() async {
    guard let client else {
      phase = .unconfigured
      status = nil
      return
    }
    let asked = generation
    do {
      let answer = try await client.status()
      guard asked == generation else { return }
      apply(answer)
    } catch {
      guard asked == generation, !PadPhase.isCancellation(error) else { return }
      phase = PadPhase(error: error)
      status = nil
    }
  }

  /// A new host or token; nil when none is set. Polls it at once.
  public func configure(_ client: PadClient?) {
    self.client = client
    generation += 1
    status = nil
    command = nil
    commandError = nil
    speedTarget = nil
    phase = client == nil ? .unconfigured : .connecting
    wake()
  }

  /// The popover shows or hides; while it shows, the store polls every second.
  public func setPopoverOpen(_ open: Bool) {
    guard open != isPopoverOpen else { return }
    isPopoverOpen = open
    if open { wake() }
  }

  /// Ends the current wait between two polls.
  public func wake() {
    nap?.cancel()
  }

  private func pause(_ duration: Duration) async {
    let sleep = sleep
    let task = Task<Void, Never> { try? await sleep(duration) }
    nap = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func apply(_ answer: Status) {
    status = answer
    phase = PadPhase(status: answer)
    guard let target = speedTarget, command != .speed else { return }
    let reported = abs((answer.speedKmh ?? 0) - target) < 0.05
    let expired =
      speedTargetSetAt.map { now().timeIntervalSince($0) > Self.speedTargetHold } ?? true
    if phase != .active || reported || expired { speedTarget = nil }
  }

  // MARK: - Commands

  /// The speed to show: the one asked for until the belt reports it, else the belt's.
  public var displayedSpeed: Double {
    speedTarget ?? status?.speedKmh ?? 0
  }

  public var canStart: Bool { command == nil && phase == .standby }
  /// Not while a speed change is in flight: the host starts a stopped belt on `/speed`, so a
  /// speed that lands after a stop would start it again.
  public var canStop: Bool { command == nil && (phase == .starting || phase == .active) }
  /// Speed changes queue behind each other, so a held hotkey ends at the last speed asked for.
  public var canChangeSpeed: Bool { phase == .active && (command == nil || command == .speed) }

  /// The hotkey: stop a moving belt, start a standing one.
  public func toggle() async {
    if canStop {
      await stop()
    } else if canStart {
      await start()
    }
  }

  /// Starts the belt at `speedKmh`, or at `startSpeed`.
  public func start(speedKmh: Double? = nil) async {
    guard canStart, let client else { return }
    let speed = SpeedRange.clamp(speedKmh ?? startSpeed)
    await perform(.start) { try await client.start(speedKmh: speed) }
  }

  public func stop() async {
    guard canStop, let client else { return }
    await perform(.stop) { try await client.stop() }
  }

  /// One or more 0.5 km/h steps up (positive) or down from the shown speed. Only while walking:
  /// `/speed` on a standing belt would start it.
  public func changeSpeed(by steps: Int) async {
    guard canChangeSpeed else { return }
    await setSpeed(SpeedRange.stepped(from: displayedSpeed, by: steps))
  }

  /// A speed for the walking belt. While one is being sent, the newest one asked for follows it.
  public func setSpeed(_ kmh: Double) async {
    guard canChangeSpeed, let client else { return }
    speedTarget = SpeedRange.clamp(kmh)
    speedTargetSetAt = now()
    guard command == nil else { return }
    command = .speed
    commandError = nil
    let asked = generation
    var sent: Double?
    while asked == generation, let target = speedTarget, target != sent {
      do {
        // A speed that queued behind the first goes out only to a belt that still walks: the
        // host starts a stopped belt on `/speed`, and the pad's remote may have stopped it.
        if sent != nil, PadPhase(status: try await client.status()) != .active { break }
        try await client.setSpeed(target)
        sent = target
      } catch {
        if !PadPhase.isCancellation(error) { commandError = PadPhase.describe(error) }
        speedTarget = nil
        break
      }
    }
    guard asked == generation else { return }
    command = nil
    await refresh()
  }

  /// Saves the pad's own start speed (`/pref/start-speed`), used when the belt starts from the
  /// pad's remote. Throws so Settings can say whether it landed.
  public func saveStartSpeedOnPad(_ kmh: Double) async throws {
    guard let client else { throw PadError.notConfigured }
    try await client.setStartSpeed(SpeedRange.clamp(kmh))
  }

  private func perform(_ kind: PadCommand, _ call: () async throws -> Void) async {
    command = kind
    commandError = nil
    let asked = generation
    do {
      try await call()
    } catch {
      if asked == generation, !PadPhase.isCancellation(error) {
        commandError = PadPhase.describe(error)
      }
    }
    guard asked == generation else { return }
    command = nil
    await refresh()
  }
}
