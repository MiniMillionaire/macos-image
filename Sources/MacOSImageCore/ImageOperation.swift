import Foundation

public enum ImageVariant: String, CaseIterable, Sendable {
  case vanilla
  case base
  case xcode
}

public enum VerificationProfile: String, CaseIterable, Sendable {
  case vanilla
  case sip
  case base
  case xcode
}

public enum ProvisioningStage: String, CaseIterable, Sendable {
  case base
  case disableSIP = "disable-sip"
}

public enum ImageOperation: Equatable, Sendable {
  case doctor
  case validate
  case buildVanilla(initialWait: String?, target: String?)
  case buildBase(source: String?, target: String?)
  case buildXcode(version: String, source: String?, target: String?)
  case importVanilla(source: String?, target: String?)
  case provision(stage: ProvisioningStage, vm: String)
  case pull(variant: ImageVariant, tag: String?)
  case push(variant: ImageVariant, tag: String?, vm: String?)
  case test(vm: String, profile: VerificationProfile)

  public var legacyArguments: [String] {
    switch self {
    case .doctor:
      ["doctor"]
    case .validate:
      ["validate"]
    case .buildVanilla(let initialWait, let target):
      ["build", "vanilla"] + positional([initialWait, target])
    case .buildBase(let source, let target):
      ["build", "base"] + positional([source, target])
    case .buildXcode(let version, let source, let target):
      ["build", "xcode", version] + positional([source, target])
    case .importVanilla(let source, let target):
      ["import", "vanilla"] + positional([source, target])
    case .provision(let stage, let vm):
      ["provision", stage.rawValue, vm]
    case .pull(let variant, let tag):
      ["pull", variant.rawValue] + positional([tag])
    case .push(let variant, let tag, let vm):
      ["push", variant.rawValue] + positional([tag, vm])
    case .test(let vm, let profile):
      ["test", vm, profile.rawValue]
    }
  }
}

private func positional(_ values: [String?]) -> [String] {
  guard let lastIndex = values.lastIndex(where: { $0 != nil }) else {
    return []
  }

  return values[...lastIndex].map { $0 ?? "" }
}
