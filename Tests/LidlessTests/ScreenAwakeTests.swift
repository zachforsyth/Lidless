import IOKit.pwr_mgt
import XCTest

private final class FakeAssertions: PowerAssertions {
    var holdError: PowerAssertionError?
    var activityError: PowerAssertionError?
    private(set) var held: Set<IOPMAssertionID> = []
    private(set) var activityCount = 0
    private var nextID: IOPMAssertionID = 1

    func hold(reason: String) throws -> [IOPMAssertionID] {
        if let holdError { throw holdError }
        let ids = [nextID, nextID + 1]
        nextID += 2
        held.formUnion(ids)
        return ids
    }

    func release(_ ids: [IOPMAssertionID]) { held.subtract(ids) }

    func declareUserActivity(reason: String) throws {
        if let activityError { throw activityError }
        activityCount += 1
    }
}

@MainActor
final class ScreenAwakeTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var fake: FakeAssertions!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        fake = FakeAssertions()
        suite = "ScreenAwakeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make() -> ScreenAwakeController {
        ScreenAwakeController(assertions: fake, defaults: defaults,
                              now: { [unowned self] in self.clock },
                              schedulesTimer: false)
    }

    func testStartWithNoLimitHoldsAssertionsUntilStopped() {
        let c = make()
        c.start(minutes: 0)
        XCTAssertTrue(c.isOn)
        XCTAssertNil(c.deadline)
        XCTAssertEqual(c.remaining, "")
        XCTAssertEqual(fake.held.count, 2)
        XCTAssertEqual(fake.activityCount, 1)

        clock += 24 * 3600
        c.tick()
        XCTAssertTrue(c.isOn, "no limit must not expire")

        c.stop()
        XCTAssertFalse(c.isOn)
        XCTAssertTrue(fake.held.isEmpty)
    }

    func testTimeLimitCountsDownAndReleases() {
        let c = make()
        c.start(minutes: 15)
        XCTAssertEqual(c.remaining, "15:00")

        clock += 60
        c.tick()
        XCTAssertEqual(c.remaining, "14:00")

        clock += 14 * 60
        c.tick()
        XCTAssertFalse(c.isOn)
        XCTAssertTrue(fake.held.isEmpty)
        XCTAssertEqual(c.remaining, "")
    }

    func testDeclaresUserActivityEveryInterval() {
        let c = make()
        c.start(minutes: 0)
        clock += ScreenAwakeController.activityInterval - 1
        c.tick()
        XCTAssertEqual(fake.activityCount, 1)
        clock += 1
        c.tick()
        XCTAssertEqual(fake.activityCount, 2)
    }

    func testRestartWhileOnKeepsOneSetOfAssertions() {
        let c = make()
        c.start(minutes: 15)
        clock += 600
        c.start(minutes: 60)
        XCTAssertEqual(fake.held.count, 2)
        XCTAssertEqual(c.remaining, "1:00:00")
        c.start(minutes: 0)
        XCTAssertNil(c.deadline)
        XCTAssertTrue(c.isOn)
    }

    func testToggleUsesAndPersistsLastDuration() {
        make().start(minutes: 120)
        let c = make()
        XCTAssertEqual(c.minutes, 120)
        c.setOn(true)
        XCTAssertEqual(c.remaining, "2:00:00")
        c.setOn(false)
        XCTAssertFalse(c.isOn)
    }

    func testHoldFailureStaysOffAndReportsError() {
        fake.holdError = PowerAssertionError(call: "hold", code: -1)
        let c = make()
        c.start(minutes: 15)
        XCTAssertFalse(c.isOn)
        XCTAssertNotNil(c.lastError)
        XCTAssertTrue(fake.held.isEmpty)
    }

    func testActivityFailureAtStartReleasesAssertions() {
        fake.activityError = PowerAssertionError(call: "activity", code: -1)
        let c = make()
        c.start(minutes: 0)
        XCTAssertFalse(c.isOn)
        XCTAssertTrue(fake.held.isEmpty)
        XCTAssertNotNil(c.lastError)
    }

    func testActivityFailureLaterStaysOnWithError() {
        let c = make()
        c.start(minutes: 0)
        fake.activityError = PowerAssertionError(call: "activity", code: -1)
        clock += ScreenAwakeController.activityInterval
        c.tick()
        XCTAssertTrue(c.isOn)
        XCTAssertNotNil(c.lastError)
    }

    /// The real IOKit path: taking the assertions must succeed and show up in
    /// the system's assertion list, and releasing them must remove them.
    func testRealAssertionsRoundTrip() throws {
        let real = IOKitPowerAssertions()
        let ids = try real.hold(reason: "LidlessTests")
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(try assertionNames().contains("LidlessTests"))
        real.release(ids)
        XCTAssertFalse(try assertionNames().contains("LidlessTests"))
    }

    private func assertionNames() throws -> [String] {
        var raw: Unmanaged<CFDictionary>?
        XCTAssertEqual(IOPMCopyAssertionsByProcess(&raw), kIOReturnSuccess)
        let byPID = try XCTUnwrap(raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
        let mine = byPID[NSNumber(value: getpid())] ?? []
        return mine.compactMap { $0[kIOPMAssertionNameKey as String] as? String }
    }
}
