import XCTest

@testable import MacOSImageCore

final class ImageOperationTests: XCTestCase {
  func testSimpleOperations() {
    XCTAssertEqual(ImageOperation.doctor.legacyArguments, ["doctor"])
    XCTAssertEqual(ImageOperation.validate.legacyArguments, ["validate"])
    XCTAssertEqual(
      ImageOperation.provision(stage: .disableSIP, vm: "guest").legacyArguments,
      ["provision", "disable-sip", "guest"]
    )
    XCTAssertEqual(
      ImageOperation.test(vm: "guest", profile: .vanilla).legacyArguments,
      ["test", "guest", "vanilla"]
    )
  }

  func testOptionalPositionalsPreserveTheirSlots() {
    XCTAssertEqual(
      ImageOperation.buildVanilla(initialWait: nil, target: "guest").legacyArguments,
      ["build", "vanilla", "", "guest"]
    )
    XCTAssertEqual(
      ImageOperation.buildBase(source: nil, target: "base").legacyArguments,
      ["build", "base", "", "base"]
    )
    XCTAssertEqual(
      ImageOperation.push(variant: .xcode, tag: nil, vm: "xcode").legacyArguments,
      ["push", "xcode", "", "xcode"]
    )
  }

  func testTrailingOptionalPositionalsAreOmitted() {
    XCTAssertEqual(
      ImageOperation.buildVanilla(initialWait: nil, target: nil).legacyArguments,
      ["build", "vanilla"]
    )
    XCTAssertEqual(
      ImageOperation.pull(variant: .base, tag: nil).legacyArguments,
      ["pull", "base"]
    )
  }

  func testLayerOperations() {
    XCTAssertEqual(
      ImageOperation.buildXcode(version: "27.0", source: "base", target: "xcode")
        .legacyArguments,
      ["build", "xcode", "27.0", "base", "xcode"]
    )
    XCTAssertEqual(
      ImageOperation.importVanilla(source: "source", target: "vanilla").legacyArguments,
      ["import", "vanilla", "source", "vanilla"]
    )
    XCTAssertEqual(
      ImageOperation.push(variant: .vanilla, tag: "27.0", vm: nil).legacyArguments,
      ["push", "vanilla", "27.0"]
    )
  }
}
