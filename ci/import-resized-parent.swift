import CryptoKit
import Darwin
import Foundation
import Virtualization

func fail(_ message: String) throws -> Never {
  throw NSError(
    domain: "OfflineParentResize", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func digest(_ file: URL) throws -> (UInt64, String) {
  let handle = try FileHandle(forReadingFrom: file)
  defer { try? handle.close() }
  var hash = SHA256()
  var count: UInt64 = 0
  while try autoreleasepool(invoking: { () -> Bool in
    guard let block = try handle.read(upToCount: 8 << 20), !block.isEmpty else { return false }
    count += UInt64(block.count)
    hash.update(data: block)
    return true
  }) {}
  return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
}

@main struct ImportNative {
  static func main() throws {
    guard CommandLine.arguments.count == 4 else {
      try fail("Expected Tart directory, source manifest and output directory")
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let manifestURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
    let manifestData = try Data(contentsOf: manifestURL)
    guard var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      manifest["schema_version"] as? Int == 1,
      manifest["construction_vm_started"] as? Bool == false,
      manifest["runtime_verified"] as? Bool == false,
      let target = manifest["target"] as? [String: String],
      target["version"] != nil, target["build"] != nil,
      let originals = manifest["files"] as? [[String: Any]],
      originals.count == 4,
      Set(originals.compactMap { $0["path"] as? String })
        == Set(["disk.img", "aux.bin", "hardware-model.bin", "machine-identifier.bin"])
    else { try fail("Expected the original unbooted native MISO manifest") }
    let configData = try Data(contentsOf: source.appendingPathComponent("config.json"))
    guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
      config["os"] as? String == "darwin", config["arch"] as? String == "arm64",
      config["diskFormat"] as? String == "raw",
      let modelString = config["hardwareModel"] as? String,
      let model = Data(base64Encoded: modelString),
      let identifierString = config["ecid"] as? String,
      let identifier = Data(base64Encoded: identifierString),
      VZMacHardwareModel(dataRepresentation: model) != nil,
      VZMacMachineIdentifier(dataRepresentation: identifier) != nil
    else { try fail("Invalid Tart hardware identity") }
    guard !FileManager.default.fileExists(atPath: output.path) else {
      try fail("Output already exists")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    try model.write(
      to: output.appendingPathComponent("hardware-model.bin"), options: .withoutOverwriting)
    try identifier.write(
      to: output.appendingPathComponent("machine-identifier.bin"), options: .withoutOverwriting)
    for (original, name) in [("disk.img", "disk.img"), ("nvram.bin", "aux.bin")] {
      guard
        clonefile(
          source.appendingPathComponent(original).path, output.appendingPathComponent(name).path,
          UInt32(CLONE_NOFOLLOW)) == 0
      else {
        try fail("Could not clone \(name): \(errno)")
      }
    }
    var files: [[String: Any]] = []
    for name in ["aux.bin", "hardware-model.bin", "machine-identifier.bin", "disk.img"] {
      let (bytes, sha256) = try digest(output.appendingPathComponent(name))
      guard let original = originals.first(where: { $0["path"] as? String == name }),
        let originalBytes = original["bytes"] as? UInt64
      else { try fail("Invalid source file record") }
      if name == "disk.img" {
        guard bytes > originalBytes else { try fail("Expected a larger resized disk") }
      } else {
        guard bytes == originalBytes, sha256 == original["sha256"] as? String else {
          try fail("Changed hardware identity: \(name)")
        }
      }
      files.append(["path": name, "bytes": bytes, "sha256": sha256])
    }
    manifest["files"] = files
    manifest["offline_tart_import"] = [
      "source_manifest_sha256": SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }
        .joined(),
      "vm_started": false,
      "disk_resized": true,
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
  }
}
