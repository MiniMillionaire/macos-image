import Foundation

public protocol CommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> Int32
}

public final class FoundationCommandRunner: CommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var activeProcess: Process?

  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> Int32 {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectoryURL
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    setActiveProcess(process)
    defer { clearActiveProcess(process) }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
          continuation.resume(returning: process.terminationStatus)
        }

        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      self.interrupt()
    }
  }

  private func setActiveProcess(_ process: Process) {
    lock.lock()
    activeProcess = process
    lock.unlock()
  }

  private func clearActiveProcess(_ process: Process) {
    lock.lock()
    if activeProcess === process {
      activeProcess = nil
    }
    lock.unlock()
  }

  private func interrupt() {
    lock.lock()
    let process = activeProcess
    lock.unlock()

    if process?.isRunning == true {
      process?.interrupt()
    }
  }
}
