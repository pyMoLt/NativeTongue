import Foundation
import XCTest

@testable import Hex

final class QwenInstallationValidatorTests: XCTestCase {
  func testManifestRoundTripAndStrictValidation() throws {
    let directory = try makeInstallation()
    defer { try? FileManager.default.removeItem(at: directory) }

    let manifest = try QwenInstallationValidator.createManifest(
      directory: directory,
      repository: "example/qwen",
      revision: "0123456789abcdef"
    )

    XCTAssertEqual(manifest.repository, "example/qwen")
    XCTAssertEqual(manifest.revision, "0123456789abcdef")
    XCTAssertEqual(Set(manifest.files.map(\.path)), Set([
      "config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "model.safetensors",
    ]))
    XCTAssertNoThrow(try QwenInstallationValidator.strictValidate(
      directory: directory,
      repository: "example/qwen",
      revision: "0123456789abcdef"
    ))
  }

  func testStrictValidationRejectsTamperedWeights() throws {
    let directory = try makeInstallation()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try QwenInstallationValidator.createManifest(
      directory: directory,
      repository: "example/qwen",
      revision: "revision"
    )

    try Data("tampered weights".utf8).write(
      to: directory.appendingPathComponent("model.safetensors"),
      options: .atomic
    )

    XCTAssertThrowsError(try QwenInstallationValidator.strictValidate(
      directory: directory,
      repository: "example/qwen",
      revision: "revision"
    ))
  }

  func testManifestCreationRejectsIncompleteInstallation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))

    XCTAssertThrowsError(try QwenInstallationValidator.createManifest(
      directory: directory,
      repository: "example/qwen",
      revision: "revision"
    ))
  }

  private func makeInstallation() throws -> URL {
    let directory = try temporaryDirectory()
    for name in QwenInstallationValidator.requiredMetadataFiles {
      try Data("test-\(name)".utf8).write(to: directory.appendingPathComponent(name))
    }
    try Data("weights".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
    return directory
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalASR-QwenValidator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
