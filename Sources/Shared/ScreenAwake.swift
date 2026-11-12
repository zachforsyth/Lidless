import Combine
import Foundation
import IOKit.pwr_mgt

/// The power assertions behind "Keep screen awake".
///
/// Unlike the lid-closed mode, this needs no root helper: any process can hold
/// these assertions, and macOS drops them automatically when the process exits,
/// so a crash can never leave the Mac stuck awake.
public protocol PowerAssertions {
    /// Takes the assertions that stop display sleep, the screen saver, and idle
    /// system sleep. Returns handles to pass to `release`.
    func hold(reason: String) throws -> [IOPMAssertionID]
    func release(_ ids: [IOPMAssertionID])
    /// Tells macOS the user is active, which resets the idle timer that starts
    /// the screen saver (what `caffeinate -u` does).
    func declareUserActivity(reason: String) throws
}

public struct PowerAssertionError: Error, Equatable, CustomStringConvertible {
    public let call: String
    public let code: Int32
    public var description: String { "\(call) failed (IOReturn \(code))" }
}

/// The real assertions, through IOKit. Matches `caffeinate -d -i -u`.
public final class IOKitPowerAssertions: PowerAssertions {
    private var activityID: IOPMAssertionID = 0

    public init() {}

    public func hold(reason: String) throws -> [IOPMAssertionID] {
        var ids: [IOPMAssertionID] = []
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep,
                     kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
            guard rc == kIOReturnSuccess else {
                release(ids)
                throw PowerAssertionError(call: "IOPMAssertionCreateWithName(\(type))", code: rc)
            }
            ids.append(id)
        }
        return ids
    }

    public func release(_ ids: [IOPMAssertionID]) {
        for id in ids { IOPMAssertionRelease(id) }
    }

    public func declareUserActivity(reason: String) throws {
        // Passing the previous ID back updates that assertion instead of
        // creating a new one each time.
        let rc = IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &activityID)
        guard rc == kIOReturnSuccess else {
            throw PowerAssertionError(call: "IOPMAssertionDeclareUserActivity", code: rc)
        }
    }
}

/// "Keep screen awake": stops display sleep and the screen saver, with an
/// optional time limit. Independent of the lid-closed mode.
@MainActor
public final class ScreenAwakeController: ObservableObject {
    @Published public private(set) var isOn = false
    /// When the time limit ends, or nil for no limit (or when off).
    @Published public private(set) var deadline: Date?
    /// Countdown text such as `1:05:09`, empty when there is no limit.
    @Published public private(set) var remaining = ""
    /// Last chosen duration in minutes (`0` = no limit). Persisted.
    @Published public private(set) var minutes: Int
    @Published public private(set) var lastError: String?

    /// How often to re-declare user activity. Well under any screen saver delay
    /// macOS allows (the shortest is one minute).
    public static let activityInterval: TimeInterval = 30
    static let reason = "Lidless: keep screen awake"
    static let minutesKey = "screenAwakeMinutes"

    private let assertions: PowerAssertions
    private let defaults: UserDefaults
    private let now: () -> Date
    private let schedulesTimer: Bool
    private var held: [IOPMAssertionID] = []
    private var lastActivity: Date?
    private var timer: Timer?

    public init(assertions: PowerAssertions = IOKitPowerAssertions(),
                defaults: UserDefaults = .standard,
                now: @escaping () -> Date = Date.init,
                schedulesTimer: Bool = true) {
        self.assertions = assertions
        self.defaults = defaults
        self.now = now
        self.schedulesTimer = schedulesTimer
        self.minutes = max(0, defaults.integer(forKey: Self.minutesKey))
    }

    /// Turns it on for the last chosen duration.
    public func setOn(_ on: Bool) {
        if on { start(minutes: minutes) } else { stop() }
    }

    /// Turns it on (or restarts the countdown) for `minutes`; `0` means no limit.
    public func start(minutes: Int) {
        let minutes = max(0, minutes)
        self.minutes = minutes
        defaults.set(minutes, forKey: Self.minutesKey)

        if !isOn {
            do {
                held = try assertions.hold(reason: Self.reason)
                try assertions.declareUserActivity(reason: Self.reason)
            } catch {
                assertions.release(held)
                held = []
                lastError = "Couldn’t keep the screen awake: \(error)"
                return
            }
            lastActivity = now()
            isOn = true
            lastError = nil
            if schedulesTimer { scheduleTimer() }
        }
        deadline = minutes > 0 ? AutoOff.deadline(from: now(), minutes: minutes) : nil
        refreshRemaining()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        assertions.release(held)
        held = []
        lastActivity = nil
        isOn = false
        deadline = nil
        remaining = ""
    }

    /// Runs once a second while on: ends the time limit and keeps the idle
    /// timer from reaching the screen saver.
    public func tick() {
        guard isOn else { return }
        let t = now()
        if let deadline, AutoOff.isExpired(deadline: deadline, now: t) {
            stop()
            return
        }
        if let last = lastActivity, t.timeIntervalSince(last) >= Self.activityInterval {
            do {
                try assertions.declareUserActivity(reason: Self.reason)
                lastActivity = t
                lastError = nil
            } catch {
                // The display assertion is still held, so stay on, but say so.
                lastError = "Couldn’t reset the idle timer: \(error)"
            }
        }
        refreshRemaining()
    }

    private func refreshRemaining() {
        guard let deadline else { remaining = ""; return }
        remaining = AutoOff.formatCountdown(AutoOff.remaining(deadline: deadline, now: now()))
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes so the countdown keeps running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
