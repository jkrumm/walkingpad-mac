import Foundation

// Wire types of the host's HTTP API (docs/protocol.md section 8, internal/api/types.go).
// contracts/fixtures holds one golden response per shape; PadKitTests decodes every file.

/// `GET /health`.
public struct Health: Codable, Equatable, Sendable {
  public let ok: Bool
  public let version: String
}

/// The body of every write route that succeeds: `{"ok":true}`.
public struct Acknowledgement: Codable, Equatable, Sendable {
  public let ok: Bool
}

/// The body of every non-2xx response.
public struct APIErrorBody: Codable, Equatable, Sendable {
  public let error: String
}

/// The belt state the host decodes from the pad's status frame. The three 3-2-1 ramp
/// frames all read `starting`; a byte the host does not know reads `unknown(<byte>)`.
public enum BeltState: Equatable, Sendable, Codable {
  case stopped, active, stopping, standby, starting
  case unknown(String)

  public init(wire: String) {
    switch wire {
    case "stopped": self = .stopped
    case "active": self = .active
    case "stopping": self = .stopping
    case "standby": self = .standby
    case "starting": self = .starting
    default: self = .unknown(wire)
    }
  }

  public var wire: String {
    switch self {
    case .stopped: "stopped"
    case .active: "active"
    case .stopping: "stopping"
    case .standby: "standby"
    case .starting: "starting"
    case .unknown(let raw): raw
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(wire: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wire)
  }
}

/// The pad's operating mode.
public enum BeltMode: Equatable, Sendable, Codable {
  case auto, manual, standby
  case unknown(String)

  public init(wire: String) {
    switch wire {
    case "auto": self = .auto
    case "manual": self = .manual
    case "standby": self = .standby
    default: self = .unknown(wire)
    }
  }

  public var wire: String {
    switch self {
    case .auto: "auto"
    case .manual: "manual"
    case .standby: "standby"
    case .unknown(let raw): raw
    }
  }

  public init(from decoder: any Decoder) throws {
    self.init(wire: try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wire)
  }
}

/// One stored status frame. `beltState` is absent in the live ring of `/status`.
public struct Sample: Codable, Equatable, Sendable {
  public let ts: Date
  public let beltState: BeltState?
  public let speedKmh: Double
  public let distanceM: Double
  public let steps: Int
}

/// The session in flight, as `/status` reports it.
public struct CurrentSession: Codable, Equatable, Sendable {
  public let uuid: String
  public let startedAt: Date
  public let durationS: Int
  public let distanceM: Double
  public let steps: Int
  public let kcal: Double
  public let avgSpeedKmh: Double
  public let maxSpeedKmh: Double
  public let samples: [Sample]
}

/// Today's totals in `/status`.
public struct DayTotals: Codable, Equatable, Sendable {
  public let durationS: Int
  public let distanceM: Double
  public let steps: Int
  public let kcal: Double
}

/// The bound peripheral.
public struct Device: Codable, Equatable, Sendable {
  public let name: String
  public let address: String
  public let rssi: Int
}

/// `GET /status`. The belt fields are absent while the pad is not connected, and the host
/// omits `speed_kmh` when it is 0.
public struct Status: Codable, Equatable, Sendable {
  public let connected: Bool
  public let beltState: BeltState?
  public let mode: BeltMode?
  public let speedKmh: Double?
  public let observedAt: Date?
  public let currentSession: CurrentSession?
  public let today: DayTotals
  public let device: Device
}

/// A stored session. `endedAt` is nil while it is open, `syncedAt` until Argo has it.
public struct Session: Codable, Equatable, Sendable {
  public let uuid: String
  public let startedAt: Date
  public let endedAt: Date?
  public let durationS: Int
  public let distanceM: Double
  public let steps: Int
  public let avgSpeedKmh: Double
  public let maxSpeedKmh: Double
  public let kcal: Double
  public let pauseCount: Int
  public let syncedAt: Date?
}

/// `GET /sessions`, newest first.
public struct SessionList: Codable, Equatable, Sendable {
  public let sessions: [Session]
}

/// `GET /sessions/{uuid}`.
public struct SessionDetail: Codable, Equatable, Sendable {
  public let session: Session
  public let samples: [Sample]
}

/// The window of `GET /summary`.
public enum SummaryPeriod: String, Codable, Sendable, CaseIterable {
  case today, week, month, all
}

/// `GET /summary`: totals over the closed sessions of a period.
public struct Summary: Codable, Equatable, Sendable {
  public let period: SummaryPeriod
  public let sessions: Int
  public let durationS: Int
  public let distanceM: Double
  public let steps: Int
  public let kcal: Double
}

/// `POST /sync/argo`.
public struct SyncResult: Codable, Equatable, Sendable {
  public let synced: Int
  public let failed: Int
}

/// The body of `/start`, `/speed` and `/pref/start-speed`.
struct SpeedRequest: Codable, Sendable {
  let speedKmh: Double
}
