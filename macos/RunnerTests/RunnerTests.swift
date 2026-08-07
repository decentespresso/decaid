import Cocoa
import FlutterMacOS
import XCTest
@testable import Decaid

/// Fake controller so MacOSUpdater can be exercised without starting Sparkle's
/// updater (which would read the host bundle and schedule network checks).
@MainActor
private final class FakeUpdaterController: SPUUpdaterControlling {
  var startCalls = 0
  var checkCalls = 0
  var resetCalls = 0
  var automaticallyChecksForUpdates = false
  var validateCalls = 0
  var throwOnValidate = false
  func validateConfiguration() throws {
    validateCalls += 1
    if throwOnValidate { throw MacOSUpdaterError.missingInfoPlistKeys }
  }

  func startUpdater() {
    startCalls += 1
  }

  func checkForUpdates() {
    checkCalls += 1
  }

  func resetUpdateCycleAfterShortDelay() {
    resetCalls += 1
  }
}

final class RunnerTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(
      forKey: MacOSUpdater.automaticChecksMigrationKey)
  }


  func testStableChannelMapsToEmptyAllowedChannels() {
    XCTAssertEqual(MacOSUpdater.allowedChannels(for: "stable"), [])
  }

  func testBetaChannelMapsToBeta() {
    XCTAssertEqual(MacOSUpdater.allowedChannels(for: "beta"), ["beta"])
  }

  func testUnknownChannelMapsToEmptyAllowedChannels() {
    XCTAssertEqual(MacOSUpdater.allowedChannels(for: "whatever"), [])
  }


  @MainActor
  func testConfigureStartsUpdaterExactlyOnce() throws {
    let fake = FakeUpdaterController()
    let updater = MacOSUpdater(controller: fake)

    try updater.configure(automaticChecks: true, channel: "stable")
    try updater.configure(automaticChecks: false, channel: "beta")

    XCTAssertEqual(fake.startCalls, 1)
    XCTAssertEqual(fake.validateCalls, 2)
  }

  @MainActor
  func testConfigureValidatesBeforeStarting() throws {
    let fake = FakeUpdaterController()
    fake.throwOnValidate = true
    let updater = MacOSUpdater(controller: fake)

    XCTAssertThrowsError(try updater.configure(automaticChecks: true, channel: "stable"))
    XCTAssertEqual(fake.startCalls, 0)
  }

  @MainActor
  func testSetAutomaticChecksOnlyAfterMigration() throws {
    let fake = FakeUpdaterController()
    let updater = MacOSUpdater(controller: fake)

    // Before configure() migrates, the setter is a no-op.
    updater.setAutomaticChecks(false)
    XCTAssertFalse(fake.automaticallyChecksForUpdates)

    try updater.configure(automaticChecks: true, channel: "stable")
    XCTAssertTrue(fake.automaticallyChecksForUpdates)

    updater.setAutomaticChecks(false)
    XCTAssertFalse(fake.automaticallyChecksForUpdates)
  }

  @MainActor
  func testChannelChangeResetsUpdateCycle() throws {
    let fake = FakeUpdaterController()
    let updater = MacOSUpdater(controller: fake)

    try updater.configure(automaticChecks: true, channel: "stable")
    XCTAssertEqual(fake.resetCalls, 0)

    updater.setChannel("beta")
    XCTAssertEqual(fake.resetCalls, 1)

    // Same channel again must not reset.
    updater.setChannel("beta")
    XCTAssertEqual(fake.resetCalls, 1)
  }

  @MainActor
  func testCheckForUpdatesDelegatesOnlyWhenConfigured() throws {
    let fake = FakeUpdaterController()
    let updater = MacOSUpdater(controller: fake)

    updater.checkForUpdates()
    XCTAssertEqual(fake.checkCalls, 0)

    try updater.configure(automaticChecks: true, channel: "stable")
    updater.checkForUpdates()
    XCTAssertEqual(fake.checkCalls, 1)
  }
}
