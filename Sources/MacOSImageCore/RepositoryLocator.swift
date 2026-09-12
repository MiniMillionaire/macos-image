import Foundation

public struct RepositoryNotFoundError: LocalizedError, Sendable {
  public let searchedFrom: String

  public var errorDescription: String? {
    "Could not find a macos-image repository from \(searchedFrom)"
  }
}

public enum RepositoryLocator {
  public static func locate(
    explicitPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> URL {
    if let explicitPath {
      let candidate = resolve(explicitPath, relativeTo: currentDirectory)
      if isRepository(candidate) {
        return candidate
      }
      throw RepositoryNotFoundError(searchedFrom: candidate.path)
    }

    if let environmentPath = environment["MACOS_IMAGE_ROOT"] {
      let candidate = resolve(environmentPath, relativeTo: currentDirectory)
      if isRepository(candidate) {
        return candidate
      }
      throw RepositoryNotFoundError(searchedFrom: candidate.path)
    }

    var candidate = currentDirectory.standardizedFileURL
    while true {
      if isRepository(candidate) {
        return candidate
      }

      let parent = candidate.deletingLastPathComponent()
      if parent.path == candidate.path {
        break
      }
      candidate = parent
    }

    throw RepositoryNotFoundError(searchedFrom: currentDirectory.path)
  }

  private static func resolve(_ path: String, relativeTo currentDirectory: URL) -> URL {
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    return currentDirectory.appendingPathComponent(path).standardizedFileURL
  }

  private static func isRepository(_ url: URL) -> Bool {
    let script = url.appendingPathComponent("scripts/image").path
    var isDirectory = ObjCBool(false)
    let hasConfig = FileManager.default.fileExists(
      atPath: url.appendingPathComponent("config").path,
      isDirectory: &isDirectory
    )
    return FileManager.default.isExecutableFile(atPath: script) && hasConfig
      && isDirectory.boolValue
  }
}
