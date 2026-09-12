import Foundation
import XCTest

@testable import MacOSImageCore

final class CommandRunnerTests: XCTestCase {
  func testReturnsProcessExitStatus() async throws {
    let status = try await FoundationCommandRunner().run(
      executableURL: URL(fileURLWithPath: "/usr/bin/false"),
      arguments: [],
      environment: [:],
      currentDirectoryURL: URL(fileURLWithPath: "/")
    )

    XCTAssertEqual(status, 1)
  }
}
