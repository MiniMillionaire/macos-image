import Foundation

public struct ImageTool: Sendable {
  public let repositoryURL: URL
  public let environment: [String: String]
  private let runner: any CommandRunning

  public init(
    repositoryURL: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runner: any CommandRunning = FoundationCommandRunner()
  ) {
    self.repositoryURL = repositoryURL
    self.environment = environment
    self.runner = runner
  }

  public func run(_ operation: ImageOperation, configuration: String? = nil) async throws -> Int32 {
    var childEnvironment = environment
    if let configuration {
      childEnvironment["IMAGE_CONFIG"] = configuration
    }

    return try await runner.run(
      executableURL: repositoryURL.appendingPathComponent("scripts/image"),
      arguments: operation.legacyArguments,
      environment: childEnvironment,
      currentDirectoryURL: repositoryURL
    )
  }
}
