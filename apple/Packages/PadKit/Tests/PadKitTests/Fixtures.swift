import Foundation
import Testing

@testable import PadKit

/// The golden responses `internal/api/contract_test.go` writes (`make contracts`).
enum Fixtures {
  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent()  // PadKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // PadKit
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // apple
    .deletingLastPathComponent()  // repo root
    .appending(path: "contracts/fixtures")

  static func data(_ name: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: "\(name).json"))
  }

  static func names() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
      .filter { $0.hasSuffix(".json") }
      .map { String($0.dropLast(".json".count)) }
      .sorted()
  }

  static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try WireCoding.decoder().decode(type, from: data(name))
  }
}
