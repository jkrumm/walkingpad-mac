import Foundation

/// Sends one request. `URLSession` is the production transport; tests pass a fake.
public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await data(for: request, delegate: nil)
  }
}

/// A failed call. Transport failures (`URLError`) pass through unchanged.
public enum PadError: Error, Equatable, Sendable {
  /// The host answered non-2xx; `message` is its `{"error":…}` body when it sent one.
  case http(status: Int, message: String?)
  /// The response was not HTTP.
  case notHTTP
  /// No host is configured.
  case notConfigured
}

/// The host's HTTP API (docs/protocol.md section 8), one method per route.
public struct PadClient: Sendable {
  public let baseURL: URL
  private let token: String?
  private let transport: any HTTPTransport

  /// A read gives up after this long; a poll that hangs reads as an unreachable host.
  public static let readTimeout: TimeInterval = 5
  /// A write may take this long: `/start` and `/speed` from a standing belt block about five
  /// seconds while the host waits out the ramp.
  public static let commandTimeout: TimeInterval = 20

  /// `token` is sent as a bearer token when it is set; the host's loopback listener needs
  /// none unless its config sets `api_token`.
  public init(baseURL: URL, token: String? = nil, transport: any HTTPTransport = URLSession.shared)
  {
    self.baseURL = baseURL
    self.token = token.flatMap { $0.isEmpty ? nil : $0 }
    self.transport = transport
  }

  public func health() async throws -> Health {
    try await get("health")
  }

  public func status() async throws -> Status {
    try await get("status")
  }

  /// Sessions newest first; `before` pages back from an instant.
  public func sessions(limit: Int? = nil, before: Date? = nil) async throws -> [Session] {
    var query: [URLQueryItem] = []
    if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let before {
      query.append(URLQueryItem(name: "before", value: WireCoding.formatDate(before)))
    }
    let list: SessionList = try await get("sessions", query: query)
    return list.sessions
  }

  public func session(uuid: String) async throws -> SessionDetail {
    try await get("sessions/\(uuid)")
  }

  public func summary(period: SummaryPeriod) async throws -> Summary {
    try await get("summary", query: [URLQueryItem(name: "period", value: period.rawValue)])
  }

  /// One total per calendar day from `from` to `to`, both inclusive, in the host's time zone.
  public func summaryDays(from: String, to: String) async throws -> DaySummaries {
    try await get(
      "summary/days",
      query: [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)])
  }

  /// Starts the belt. The host waits out the 3-2-1 ramp before it applies `speedKmh`, so
  /// the call takes about five seconds. Without a speed the belt keeps its stored one.
  public func start(speedKmh: Double? = nil) async throws {
    let body = speedKmh.map { SpeedRequest(speedKmh: $0) }
    let _: Acknowledgement = try await send("POST", "start", body: body)
  }

  public func stop() async throws {
    let _: Acknowledgement = try await send("POST", "stop", body: SpeedRequest?.none)
  }

  /// 0.5 to 6.0 km/h; the host rounds to 0.1 and rejects anything outside with a 400.
  public func setSpeed(_ speedKmh: Double) async throws {
    let _: Acknowledgement = try await send(
      "POST", "speed", body: SpeedRequest(speedKmh: speedKmh))
  }

  /// The speed the pad ramps to when it starts without one.
  public func setStartSpeed(_ speedKmh: Double) async throws {
    let _: Acknowledgement = try await send(
      "POST", "pref/start-speed", body: SpeedRequest(speedKmh: speedKmh))
  }

  public func syncArgo() async throws -> SyncResult {
    try await send("POST", "sync/argo", body: SpeedRequest?.none)
  }

  // MARK: - Request plumbing

  private func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = [])
    async throws -> Response
  {
    try await send("GET", path, query: query, body: SpeedRequest?.none)
  }

  private func send<Body: Encodable, Response: Decodable>(
    _ method: String, _ path: String, query: [URLQueryItem] = [], body: Body?
  ) async throws -> Response {
    var url = baseURL.appending(path: path)
    if !query.isEmpty { url.append(queryItems: query) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = method == "GET" ? Self.readTimeout : Self.commandTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpBody = try WireCoding.encoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await transport.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw PadError.notHTTP }
    guard (200..<300).contains(http.statusCode) else {
      let message = try? WireCoding.decoder().decode(APIErrorBody.self, from: data).error
      throw PadError.http(status: http.statusCode, message: message)
    }
    return try WireCoding.decoder().decode(Response.self, from: data)
  }
}
