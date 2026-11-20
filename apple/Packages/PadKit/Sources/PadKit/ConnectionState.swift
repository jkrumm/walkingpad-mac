import Foundation

/// What the menu bar shows about the link app → host → pad.
public enum ConnectionState: Equatable, Sendable {
  /// No answer yet.
  case unknown
  /// The host did not answer; the reason is the error's description.
  case hostUnreachable(String)
  /// The host answered but holds no BLE link to the pad.
  case padDisconnected
  /// The pad is connected; the belt state is nil before its first frame.
  case connected(BeltState?)

  public init(status: Status) {
    self = status.connected ? .connected(status.beltState) : .padDisconnected
  }

  public init(error: any Error) {
    switch error {
    case PadError.http(let status, let message):
      self = .hostUnreachable(message.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)")
    default:
      self = .hostUnreachable(error.localizedDescription)
    }
  }

  /// One line for the menu bar popover.
  public var summary: String {
    switch self {
    case .unknown: "Connecting…"
    case .hostUnreachable(let reason): "Host unreachable: \(reason)"
    case .padDisconnected: "Host up, pad not connected"
    case .connected(let belt): "Pad connected, belt \(belt?.wire ?? "unknown")"
    }
  }
}
