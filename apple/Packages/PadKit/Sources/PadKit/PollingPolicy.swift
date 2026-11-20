/// How often the store asks `GET /status`: every second while the belt moves, a session is open or
/// the popover shows, every ten seconds otherwise, and not at all without a host.
public enum PollingPolicy {
  public static let fast: Duration = .seconds(1)
  public static let slow: Duration = .seconds(10)

  /// nil: nothing to poll until the host is configured.
  public static func interval(phase: PadPhase, sessionOpen: Bool, popoverOpen: Bool) -> Duration? {
    if phase == .unconfigured { return nil }
    return phase.isMoving || sessionOpen || popoverOpen ? fast : slow
  }
}
