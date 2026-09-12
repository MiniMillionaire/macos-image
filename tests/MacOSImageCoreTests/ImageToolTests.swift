import Foundation
import XCTest

@testable import MacOSImageCore

final class ImageToolTests: XCTestCase {
  func testRunsLegacyBackendWithConfiguration() async throws {
    let runner = RecordingRunner(status: 7)
    let repository = URL(fileURLWithPath: "/repository")
    let tool = ImageTool(
      repositoryURL: repository,
      environment: ["EXISTING": "value"],
      runner: runner
    )

    let status = try await tool.run(
      .buildVanilla(initialWait: "90s", target: "guest"),
      configuration: "config/test.env"
    )

    XCTAssertEqual(status, 7)
    let recordedInvocation = await runner.invocation
    let invocation = try XCTUnwrap(recordedInvocation)
    XCTAssertEqual(invocation.executableURL.path, "/repository/scripts/image")
    XCTAssertEqual(invocation.arguments, ["build", "vanilla", "90s", "guest"])
    XCTAssertEqual(invocation.environment["EXISTING"], "value")
    XCTAssertEqual(invocation.environment["IMAGE_CONFIG"], "config/test.env")
    XCTAssertEqual(invocation.currentDirectoryURL.path, "/repository")
  }
}

private actor RecordingRunner: CommandRunning {
  struct Invocation {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL
  }

  private let status: Int32
  private(set) var invocation: Invocation?

  init(status: Int32) {
    self.status = status
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> Int32 {
    invocation = Invocation(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    return status
  }
}
