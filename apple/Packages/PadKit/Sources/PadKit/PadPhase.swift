import Foundation

/// What the app knows about the chain app → host → pad, as one state. The popover, the menu bar
/// item, the polling interval and which controls are enabled all read it.
public enum PadPhase: Equatable, Sendable {
  /// No host URL is set.
  case unconfigured
  /// A host is set and has not answered yet.
  case connecting
  /// The host did not answer, or answered with an error other than 401; the reason is shown.
  case hostUnreachable(String)
  /// The host refused the bearer token.
  case unauthorized
  /// The host answered but holds no BLE link to the pad.
  case padDisconnected
  /// The pad is connected and the belt does not move. The host's `stopped`, `standby`, a belt
  /// state it has not decoded yet and a byte it does not know all read as this.
  case standby
  /// The 3-2-1 ramp.
  case starting
  case active
  case stopping

  public init(status: Status) {
    guard status.connected else {
      self = .padDisconnected
      return
    }
    switch status.beltState {
    case .starting: self = .starting
    case .active: self = .active
    case .stopping: self = .stopping
    case .stopped, .standby, .unknown, nil: self = .standby
    }
  }

  public init(error: any Error) {
    if case PadError.http(status: 401, _) = error {
      self = .unauthorized
      return
    }
    self = .hostUnreachable(Self.describe(error))
  }

  /// The belt moves or is about to.
  public var isMoving: Bool {
    switch self {
    case .starting, .active, .stopping: true
    default: false
    }
  }

  /// The host answered with a pad behind it.
  public var hasPad: Bool {
    switch self {
    case .standby, .starting, .active, .stopping: true
    default: false
    }
  }

  /// A short title for the popover's header.
  public var title: String {
    switch self {
    case .unconfigured: "Not set up"
    case .connecting: "Connecting…"
    case .hostUnreachable: "Host unreachable"
    case .unauthorized: "Token refused"
    case .padDisconnected: "Pad not connected"
    case .standby: "Ready"
    case .starting: "Starting…"
    case .active: "Walking"
    case .stopping: "Stopping…"
    }
  }

  /// One sentence on what is wrong and what helps; nil when nothing is.
  public var advice: String? {
    switch self {
    case .unconfigured: "Enter the host's URL in Settings."
    case .connecting: nil
    case .hostUnreachable(let reason): "\(reason). Is the host running and reachable?"
    case .unauthorized: "The host refused the token. Check it in Settings."
    case .padDisconnected: "The host is up but has no Bluetooth link to the pad. Switch the pad on."
    case .standby, .starting, .active, .stopping: nil
    }
  }

  /// A failed call as one short line: the host's error body, or the transport's reason.
  public static func describe(_ error: any Error) -> String {
    switch error {
    case PadError.http(let status, let message):
      return message.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)"
    case PadError.notHTTP:
      return "Not an HTTP answer"
    case let urlError as URLError:
      switch urlError.code {
      case .timedOut: return "Timed out"
      case .cannotConnectToHost: return "Connection refused"
      case .cannotFindHost, .dnsLookupFailed: return "Host not found"
      case .notConnectedToInternet, .networkConnectionLost: return "Network is down"
      default: return urlError.localizedDescription
      }
    default:
      return error.localizedDescription
    }
  }

  /// A cancelled request: the caller went away, nothing to show.
  public static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
  }
}
