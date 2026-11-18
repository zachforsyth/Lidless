import Foundation
import IOKit

/// "Lock when lid opens": while on, the screen locks the moment the lid goes
/// from closed to open. Pairs with the lid-closed keep-awake mode, where the Mac
/// keeps running with the lid shut and would otherwise wake straight to the
/// desktop. Needs no helper: reading the lid state and locking the screen both
/// work from the unprivileged app.

/// Reads the lid (clamshell) state and reports when it may have changed.
public protocol LidSensor: AnyObject {
    /// `true` when closed, `false` when open, `nil` when unknown (no built-in
    /// lid, as on a desktop Mac, or the read failed).
    func isLidClosed() -> Bool?
    /// Calls `onChange` on the main queue whenever the lid state may have
    /// changed. The caller re-reads `isLidClosed()` to find out.
    func startObserving(_ onChange: @escaping () -> Void) throws
    func stopObserving()
}

/// Locks the screen.
public protocol ScreenLocker {
    func lock() throws
}

public struct LidLockError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The lid state from `AppleClamshellState` on `IOPMrootDomain`, which is what
/// `ioreg -r -k AppleClamshellState` shows. Change notifications come from the
/// root domain's general interest messages, which include
/// `kIOPMMessageClamshellStateChange`.
public final class IOKitLidSensor: LidSensor {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var onChange: (() -> Void)?

    public init() {}

    deinit { stopObserving() }

    public func isLidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    public func startObserving(_ onChange: @escaping () -> Void) throws {
        stopObserving()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw LidLockError("IONotificationPortCreate failed")
        }
        IONotificationPortSetDispatchQueue(port, .main)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else {
            IONotificationPortDestroy(port)
            throw LidLockError("IOPMrootDomain not found")
        }
        defer { IOObjectRelease(root) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let rc = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            Unmanaged<IOKitLidSensor>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }, refcon, &notifier)
        guard rc == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            throw LidLockError("IOServiceAddInterestNotification failed (\(rc))")
        }
        self.port = port
        self.onChange = onChange
    }

    public func stopObserving() {
        if notifier != 0 {
            IOObjectRelease(notifier)
            notifier = 0
        }
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
        onChange = nil
    }
}

/// Locks the screen the way the Apple menu's Lock Screen item does, through
/// `SACLockScreenImmediate` in the private `login.framework`. Private API, so a
/// macOS update could remove it; `isAvailable` reports whether it resolved, and
/// `lock()` throws rather than silently doing nothing.
public final class LoginFrameworkScreenLocker: ScreenLocker {
    /// Declared as returning nothing: the return value is undocumented, and
    /// ignoring it is ABI-safe.
    private typealias LockFunction = @convention(c) () -> Void
    private static let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    private let function: LockFunction?

    public init() {
        if let handle = dlopen(Self.path, RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            function = unsafeBitCast(symbol, to: LockFunction.self)
        } else {
            function = nil
        }
    }

    public var isAvailable: Bool { function != nil }

    public func lock() throws {
        guard let function else {
            throw LidLockError("SACLockScreenImmediate isn’t available on this version of macOS")
        }
        function()
    }
}

/// The pure rule: lock only on a real closed-to-open change.
public enum LidTransition {
    public static func shouldLock(previous: Bool?, current: Bool?) -> Bool {
        previous == true && current == false
    }
}

@MainActor
public final class LidLockController: ObservableObject {
    @Published public private(set) var isOn: Bool
    @Published public private(set) var lastError: String?
    /// False when the Mac has no readable lid (a desktop), so the control can be
    /// disabled instead of looking live and doing nothing.
    @Published public private(set) var lidAvailable: Bool

    /// Backup poll in case a change notification is missed. Reading one
    /// registry property is cheap.
    public static let pollInterval: TimeInterval = 1
    static let enabledKey = "lockOnLidOpen"

    private let sensor: LidSensor
    private let locker: ScreenLocker
    private let defaults: UserDefaults
    private let schedulesTimer: Bool
    /// Last lid state seen while on; nil until the first read.
    private var lastClosed: Bool?
    private var timer: Timer?

    public init(sensor: LidSensor = IOKitLidSensor(),
                locker: ScreenLocker = LoginFrameworkScreenLocker(),
                defaults: UserDefaults = .standard,
                schedulesTimer: Bool = true) {
        self.sensor = sensor
        self.locker = locker
        self.defaults = defaults
        self.schedulesTimer = schedulesTimer
        self.isOn = false
        self.lidAvailable = sensor.isLidClosed() != nil
        if defaults.bool(forKey: Self.enabledKey) { setOn(true) }
    }

    public func setOn(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// Re-reads the lid and locks on a closed-to-open change.
    public func lidMayHaveChanged() {
        guard isOn else { return }
        let current = sensor.isLidClosed()
        lidAvailable = current != nil
        defer { if current != nil { lastClosed = current } }
        guard LidTransition.shouldLock(previous: lastClosed, current: current) else { return }
        do {
            try locker.lock()
            lastError = nil
        } catch {
            lastError = "Couldn’t lock the screen: \(error)"
        }
    }

    private func start() {
        guard !isOn else { return }
        // Baseline from the current state, so turning it on (or launching) with
        // the lid open never locks.
        lastClosed = sensor.isLidClosed()
        lidAvailable = lastClosed != nil
        do {
            try sensor.startObserving { [weak self] in
                Task { @MainActor in self?.lidMayHaveChanged() }
            }
            lastError = nil
        } catch {
            // The poll below still catches the change, a second late at most.
            lastError = "Lid change notifications are unavailable (\(error)); checking every second instead."
        }
        isOn = true
        if schedulesTimer { scheduleTimer() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        sensor.stopObserving()
        isOn = false
        lastClosed = nil
        lastError = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.lidMayHaveChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
