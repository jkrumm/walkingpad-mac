#if SNAPSHOT_HARNESS
  import Foundation
  import PadKit

  /// A host in memory: `/status` answers the scenario's JSON or fails as it says, writes answer
  /// `{"ok":true}` or never (to draw a command in flight). Nothing leaves the process.
  struct SnapshotHost: HTTPTransport {
    enum Answer: Sendable {
      case json(String)
      case http(Int, String)
      case unreachable
    }

    let status: Answer
    var holdWrites = false
    /// Other GET routes, by path or by path and query ("/summary?period=week"); `/status` falls
    /// back to `status`.
    var routes: [String: Answer] = [:]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
      guard let url = request.url else { throw URLError(.badURL) }
      if request.httpMethod != "GET" {
        if holdWrites { try await Task.sleep(for: .seconds(3600)) }
        return try reply(url, 200, #"{"ok":true}"#)
      }
      let path = url.path(percentEncoded: false)
      let routed = routes[path + (url.query().map { "?" + $0 } ?? "")] ?? routes[path]
      switch routed ?? status {
      case .json(let body): return try reply(url, 200, body)
      case .http(let code, let body): return try reply(url, code, body)
      case .unreachable: throw URLError(.cannotConnectToHost)
      }
    }

    private func reply(_ url: URL, _ code: Int, _ body: String) throws -> (Data, URLResponse) {
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: code, httpVersion: nil, headerFields: nil)
      else { throw URLError(.badServerResponse) }
      return (Data(body.utf8), response)
    }
  }

  /// `/status` bodies in the host's wire shape (contracts/fixtures), with realistic numbers.
  enum SnapshotStatus {
    static let device =
      #"{"name":"WalkingPad","address":"00000000-0000-0000-0000-000000000001","rssi":-58}"#
    static let today = #"{"duration_s":2460,"distance_m":2870,"steps":4120,"kcal":151}"#
    static let noDevice = #"{"name":"","address":"","rssi":0}"#

    static let disconnected = """
      {"connected":false,"current_session":null,"today":\(today),"device":\(noDevice)}
      """

    static let standby = """
      {"connected":true,"belt_state":"standby","mode":"standby","observed_at":"2026-11-20T09:41:00Z",\
      "current_session":null,"today":\(today),"device":\(device)}
      """

    static func walking(_ belt: String, speed: Double, durationS: Int, distanceM: Double) -> String
    {
      """
      {"connected":true,"belt_state":"\(belt)","mode":"manual",\
      \(speed > 0 ? "\"speed_kmh\":\(speed)," : "")"observed_at":"2026-11-20T09:41:00Z",\
      "current_session":{"uuid":"5e4d3c2b-1a09-4f8e-9d7c-6b5a49382716",\
      "started_at":"2026-11-20T09:15:00Z","duration_s":\(durationS),"distance_m":\(distanceM),\
      "steps":\(Int(distanceM * 1.43)),"kcal":\(Int(distanceM / 19.7)),"avg_speed_kmh":4.2,\
      "max_speed_kmh":4.5,"samples":\(samples(durationS: durationS))},\
      "today":\(today),"device":\(device)}
      """
    }

    /// The last minute, one sample a second, easing up to 4.5 km/h.
    private static func samples(durationS: Int) -> String {
      guard durationS > 60 else { return "[]" }
      let start = Date(timeIntervalSince1970: 1_795_167_600)
      let items = (0..<60).map { second -> String in
        let speed = 4.0 + 0.5 * min(Double(second) / 40, 1)
        let ts = WireCoding.formatDate(start.addingTimeInterval(Double(second)))
        return #"{"ts":"\#(ts)","speed_kmh":\#(speed),"distance_m":0,"steps":0}"#
      }
      return "[\(items.joined(separator: ","))]"
    }
  }
#endif
