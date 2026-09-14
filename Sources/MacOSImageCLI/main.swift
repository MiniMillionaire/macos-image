import ArgumentParser
import Foundation
import MacOSImageCore

extension ImageVariant: ExpressibleByArgument {}
extension ProvisioningStage: ExpressibleByArgument {}
extension VerificationProfile: ExpressibleByArgument {}

struct CommonOptions: ParsableArguments {
  @Option(help: "Path to the macos-image repository.")
  var repository: String?

  @Option(help: "Image configuration path relative to the repository.")
  var config: String?
}

protocol ImageSubcommand: AsyncParsableCommand {
  var common: CommonOptions { get }
  var operation: ImageOperation { get }
}

extension ImageSubcommand {
  mutating func run() async throws {
    let repositoryURL = try RepositoryLocator.locate(explicitPath: common.repository)
    let status = try await ImageTool(repositoryURL: repositoryURL).run(
      operation,
      configuration: common.config
    )
    if status != 0 {
      throw ExitCode(status)
    }
  }
}

@main
struct MacOSImageCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macos-image",
    abstract: "Build and publish macOS images for Tart.",
    version: "0.1.0",
    subcommands: [
      DoctorCommand.self,
      ValidateCommand.self,
      BuildCommand.self,
      ImportCommand.self,
      ProvisionCommand.self,
      PullCommand.self,
      PushCommand.self,
      TestCommand.self,
    ]
  )
}

struct DoctorCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check the host and selected image configuration."
  )

  @OptionGroup var common: CommonOptions
  var operation: ImageOperation { .doctor }
}

struct ValidateCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "validate",
    abstract: "Validate templates, scripts, and source code."
  )

  @OptionGroup var common: CommonOptions
  var operation: ImageOperation { .validate }
}

struct BuildCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build",
    abstract: "Build an image layer.",
    subcommands: [
      BuildVanillaCommand.self,
      BuildBaseCommand.self,
      BuildXcodeCommand.self,
    ]
  )
}

struct BuildVanillaCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "vanilla",
    abstract: "Build a vanilla image from the pinned restore image."
  )

  @OptionGroup var common: CommonOptions

  @Option(help: "Initial Setup Assistant wait duration.")
  var initialWait: String?

  @Option(help: "Name for the new local VM.")
  var target: String?

  var operation: ImageOperation {
    .buildVanilla(initialWait: initialWait, target: target)
  }
}

struct BuildBaseCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "base",
    abstract: "Build a base image from a vanilla image."
  )

  @OptionGroup var common: CommonOptions

  @Option(help: "Source vanilla VM or OCI reference.")
  var source: String?

  @Option(help: "Name for the new local VM.")
  var target: String?

  var operation: ImageOperation {
    .buildBase(source: source, target: target)
  }
}

struct BuildXcodeCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "xcode",
    abstract: "Build an Xcode image from a base image."
  )

  @OptionGroup var common: CommonOptions

  @Argument(help: "Xcode version matching the cached XIP archive.")
  var version: String

  @Option(help: "Source base VM or OCI reference.")
  var source: String?

  @Option(help: "Name for the new local VM.")
  var target: String?

  var operation: ImageOperation {
    .buildXcode(version: version, source: source, target: target)
  }
}

struct ImportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract: "Import an existing local image.",
    subcommands: [ImportVanillaCommand.self]
  )
}

struct ImportVanillaCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "vanilla",
    abstract: "Import and verify an existing vanilla VM."
  )

  @OptionGroup var common: CommonOptions

  @Option(help: "Existing local vanilla VM.")
  var source: String?

  @Option(help: "Name for the imported VM.")
  var target: String?

  var operation: ImageOperation {
    .importVanilla(source: source, target: target)
  }
}

struct ProvisionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "provision",
    abstract: "Resume a provisioning stage on an existing VM.",
    subcommands: [
      ProvisionBaseCommand.self,
      ProvisionDisableSIPCommand.self,
    ]
  )
}

struct ProvisionBaseCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "base",
    abstract: "Provision the base layer on an existing VM."
  )

  @OptionGroup var common: CommonOptions

  @Argument(help: "Existing local VM.")
  var vm: String

  var operation: ImageOperation { .provision(stage: .base, vm: vm) }
}

struct ProvisionDisableSIPCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "disable-sip",
    abstract: "Disable SIP on an existing VM."
  )

  @OptionGroup var common: CommonOptions

  @Argument(help: "Existing local VM.")
  var vm: String

  var operation: ImageOperation { .provision(stage: .disableSIP, vm: vm) }
}

struct PullCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "pull",
    abstract: "Pull an image from the configured OCI registry."
  )

  @OptionGroup var common: CommonOptions

  @Argument(help: "Image layer to pull. Xcode labels require XCODE_VERSION.")
  var variant: ImageVariant

  @Option(
    help: "OCI tag. Vanilla and base use latest; Xcode also accepts latest with XCODE_VERSION."
  )
  var tag: String?

  var operation: ImageOperation { .pull(variant: variant, tag: tag) }
}

struct PushCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "push",
    abstract: "Push a local image to the configured OCI registry."
  )

  @OptionGroup var common: CommonOptions

  @Argument(help: "Image layer to push. Xcode requires XCODE_VERSION.")
  var variant: ImageVariant

  @Option(
    help: "OCI tag. Vanilla and base use latest; Xcode requires a versioned tag."
  )
  var tag: String?

  @Option(help: "Local VM name. Required for Xcode images.")
  var vm: String?

  var operation: ImageOperation { .push(variant: variant, tag: tag, vm: vm) }
}

struct TestCommand: ImageSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "test",
    abstract: "Verify an image through a disposable clone."
  )

  @OptionGroup var common: CommonOptions

  @Argument(help: "Local VM to verify.")
  var vm: String

  @Option(help: "Verification profile. Xcode requires XCODE_VERSION.")
  var profile: VerificationProfile = .base

  var operation: ImageOperation { .test(vm: vm, profile: profile) }
}
