import Foundation
import XCTest

@testable import MacOSImageCore

final class RepositoryLocatorTests: XCTestCase {
  func testFindsRepositoryFromDescendant() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let descendant = root.appendingPathComponent("Sources/Feature")
    try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)

    XCTAssertEqual(
      try RepositoryLocator.locate(environment: [:], currentDirectory: descendant),
      root.standardizedFileURL
    )
  }

  func testExplicitPathTakesPrecedenceOverEnvironment() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertEqual(
      try RepositoryLocator.locate(
        explicitPath: root.path,
        environment: ["MACOS_IMAGE_ROOT": "/missing"],
        currentDirectory: URL(fileURLWithPath: "/")
      ),
      root.standardizedFileURL
    )
  }

  func testRejectsInvalidExplicitPath() {
    XCTAssertThrowsError(
      try RepositoryLocator.locate(
        explicitPath: "/missing",
        environment: [:],
        currentDirectory: URL(fileURLWithPath: "/")
      )
    )
  }

  private func makeRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let scripts = root.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("config"),
      withIntermediateDirectories: true
    )
    let script = scripts.appendingPathComponent("image")
    try Data("#!/bin/sh\n".utf8).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: script.path
    )
    return root
  }
}
