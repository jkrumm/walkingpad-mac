import Foundation
import Observation
import PadKit

/// The host's connection state for the popover. Reads only: the controls come with the
/// menu bar row (docs/plan.yaml app-menubar).
@MainActor
@Observable
final class HostModel {
  /// The host's loopback listener on the mini; the tailnet door replaces it on the MacBook.
  static let defaultHostURL = URL(string: "http://127.0.0.1:7706")!

  private(set) var state: ConnectionState = .unknown
  private let client: PadClient

  init(client: PadClient) {
    self.client = client
  }

  func refresh() async {
    do {
      state = ConnectionState(status: try await client.status())
    } catch {
      state = ConnectionState(error: error)
    }
  }
}
