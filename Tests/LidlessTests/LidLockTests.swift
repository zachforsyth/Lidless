import XCTest

private final class FakeLidSensor: LidSensor {
    var closed: Bool? = false
    var observeError: LidLockError?
    private(set) var onChange: (() -> Void)?

    func isLidClosed() -> Bool? { closed }

    func startObserving(_ onChange: @escaping () -> Void) throws {
        if let observeError { throw observeError }
        self.onChange = onChange
    }

    func stopObserving() { onChange = nil }
}

private final class FakeLocker: ScreenLocker {
    var error: LidLockError?
    private(set) var lockCount = 0

    func lock() throws {
        if let error { throw error }
        lockCount += 1
    }
}

@MainActor
final class LidLockTests: XCTestCase {
    private var sensor: FakeLidSensor!
    private var locker: FakeLocker!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        sensor = FakeLidSensor()
        locker = FakeLocker()
        suite = "LidLockTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make() -> LidLockController {
        LidLockController(sensor: sensor, locker: locker, defaults: defaults, schedulesTimer: false)
    }

    func testTransitionRule() {
        XCTAssertTrue(LidTransition.shouldLock(previous: true, current: false))
        XCTAssertFalse(LidTransition.shouldLock(previous: false, current: false))
        XCTAssertFalse(LidTransition.shouldLock(previous: false, current: true))
        XCTAssertFalse(LidTransition.shouldLock(previous: true, current: true))
        XCTAssertFalse(LidTransition.shouldLock(previous: nil, current: false))
        XCTAssertFalse(LidTransition.shouldLock(previous: true, current: nil))
    }

    func testLocksWhenLidOpensAfterClosing() {
        let c = make()
        c.setOn(true)
        sensor.closed = true
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 0, "closing must not lock")
        sensor.closed = false
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 1)
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 1, "staying open must not lock again")
    }

    func testChangeNotificationTriggersCheck() async {
        let c = make()
        c.setOn(true)
        sensor.closed = true
        sensor.onChange?()
        await Task.yield()
        sensor.closed = false
        sensor.onChange?()
        for _ in 0..<10 where locker.lockCount == 0 { await Task.yield() }
        XCTAssertEqual(locker.lockCount, 1)
        _ = c
    }

    func testTurningOnWithLidOpenDoesNotLock() {
        let c = make()
        c.setOn(true)
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 0)
    }

    func testTurningOnWithLidClosedLocksOnOpen() {
        sensor.closed = true      // e.g. clamshell mode on an external display
        let c = make()
        c.setOn(true)
        sensor.closed = false
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 1)
    }

    func testOffNeverLocks() {
        let c = make()
        sensor.closed = true
        c.lidMayHaveChanged()
        sensor.closed = false
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 0)
    }

    func testTurningOffDropsBaselineAndObserver() {
        let c = make()
        c.setOn(true)
        sensor.closed = true
        c.lidMayHaveChanged()
        c.setOn(false)
        XCTAssertNil(sensor.onChange)
        sensor.closed = false
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 0)
    }

    func testUnknownReadingKeepsBaseline() {
        let c = make()
        c.setOn(true)
        sensor.closed = true
        c.lidMayHaveChanged()
        sensor.closed = nil
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 0)
        sensor.closed = false
        c.lidMayHaveChanged()
        XCTAssertEqual(locker.lockCount, 1, "a failed read between close and open must not hide the open")
    }

    func testNoLidReportsUnavailable() {
        sensor.closed = nil
        let c = make()
        XCTAssertFalse(c.lidAvailable)
    }

    func testLockFailureIsReported() {
        let c = make()
        c.setOn(true)
        sensor.closed = true
        c.lidMayHaveChanged()
        locker.error = LidLockError("nope")
        sensor.closed = false
        c.lidMayHaveChanged()
        XCTAssertEqual(c.lastError, "Couldn’t lock the screen: nope")
    }

    func testObserveFailureStaysOnWithNotice() {
        sensor.observeError = LidLockError("boom")
        let c = make()
        c.setOn(true)
        XCTAssertTrue(c.isOn)
        XCTAssertNotNil(c.lastError)
    }

    func testSettingPersistsAcrossLaunches() {
        make().setOn(true)
        XCTAssertTrue(make().isOn)
        make().setOn(false)
        XCTAssertFalse(make().isOn)
    }

    /// The real lid read. Skipped on Macs without a lid.
    func testRealSensorReadsLid() throws {
        guard IOKitLidSensor().isLidClosed() != nil else {
            throw XCTSkip("No built-in lid on this Mac")
        }
        let sensor = IOKitLidSensor()
        XCTAssertNoThrow(try sensor.startObserving {})
        sensor.stopObserving()
    }

    /// Resolves the private lock function without calling it (calling it would
    /// lock the screen of whoever runs the tests).
    func testRealLockerResolves() {
        XCTAssertTrue(LoginFrameworkScreenLocker().isAvailable)
    }
}
