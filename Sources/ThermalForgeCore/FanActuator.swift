//
//  FanActuator.swift
//  ThermalForge
//
//  Delivers the controller's desired fan state to the daemon and keeps it
//  there. Callers state *what* the fans should be doing; the actuator sends
//  only what is needed, one command at a time and off the caller's thread,
//  and keeps retrying with backoff after a failure instead of giving up.
//

import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable, Sendable {
    case setMax
    case setRPM(Float)
    case setFan(index: Int, rpm: Float)
    case resetAuto
    /// Synchronize the app's configurable safety threshold with the daemon.
    case setSafetyLimit(Float)

    /// A hold keeps fans at a manual setting (so an unsupervised one-shot could
    /// be reverted by the watchdog); resetAuto hands control back and isn't held.
    public var isHold: Bool {
        switch self {
        case .setMax, .setRPM, .setFan: return true
        case .resetAuto, .setSafetyLimit: return false
        }
    }

    /// Per-fan commands need the 0.1.5 `setfan` socket verb; older daemons
    /// reject them, so the router must version-gate and fall back to direct SMC.
    public var isPerFan: Bool {
        if case .setFan = self { return true }
        return false
    }
}

/// The fan state the app wants.
public enum FanTarget: Equatable, Sendable, CustomStringConvertible {
    /// Apple Auto: macOS controls the fans.
    case system
    /// Every fan at one RPM.
    case rpm(Int)
    /// Each fan at its own RPM, by fan index.
    case perFan([Int])

    public var commands: [FanCommand] {
        switch self {
        case .system: return [.resetAuto]
        case .rpm(let rpm): return [.setRPM(Float(rpm))]
        case .perFan(let rpms): return rpms.enumerated().map { .setFan(index: $0.offset, rpm: Float($0.element)) }
        }
    }

    public var description: String {
        switch self {
        case .system: return "Apple Auto"
        case .rpm(let rpm): return "\(rpm) RPM"
        case .perFan(let rpms): return rpms.map { "\($0)" }.joined(separator: "/") + " RPM"
        }
    }

    /// Small RPM steps are not worth a command: fan inertia hides them and the
    /// daemon rate-limits writes.
    func isClose(to other: FanTarget, tolerance: Int) -> Bool {
        switch (self, other) {
        case (.system, .system): return true
        case let (.rpm(a), .rpm(b)): return abs(a - b) < tolerance
        case let (.perFan(a), .perFan(b)):
            return a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < tolerance }
        default: return false
        }
    }
}

// MARK: - Actuator

public final class FanActuator: @unchecked Sendable {
    /// Applies one target. Blocking I/O is fine: it runs on the actuator's queue.
    public typealias Perform = @Sendable (FanTarget) throws -> Void

    public enum Health: Equatable, Sendable {
        case ok
        /// Consecutive failures and the latest error; still retrying.
        case retrying(failures: Int, message: String)
    }

    /// RPM changes smaller than this are not sent.
    public static let rpmTolerance = 25
    /// Minimum spacing between ramp updates. Mode changes are not delayed.
    public static let minimumInterval: TimeInterval = 0.25
    /// Failures before the app is told about them (a single blip stays quiet).
    public static let reportAfterFailures = 2

    private let queue: DispatchQueue
    private let perform: Perform
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()

    // Guarded by `lock`.
    private var desired: FanTarget?
    private var confirmed: FanTarget?
    private var inFlight = false
    private var paused = false
    private var failures = 0
    private var lastSendAt: TimeInterval = -.infinity
    private var nextAttemptAt: TimeInterval = -.infinity
    private var health: Health = .ok

    /// Called on the actuator's queue when health changes.
    public var onHealthChange: (@Sendable (Health) -> Void)?
    /// Called on the actuator's queue after each attempt (target, error or nil).
    public var onAttempt: (@Sendable (FanTarget, Error?) -> Void)?

    public init(queue: DispatchQueue = DispatchQueue(label: "com.thermalforge.actuator", qos: .userInitiated),
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                perform: @escaping Perform) {
        self.queue = queue
        self.now = now
        self.perform = perform
    }

    /// The target the daemon last accepted, if any.
    public var confirmedTarget: FanTarget? {
        lock.lock(); defer { lock.unlock() }
        return confirmed
    }

    public var desiredTarget: FanTarget? {
        lock.lock(); defer { lock.unlock() }
        return desired
    }

    public var currentHealth: Health {
        lock.lock(); defer { lock.unlock() }
        return health
    }

    /// Ask for a fan state. Cheap; call it on every control tick.
    public func request(_ target: FanTarget) {
        lock.lock()
        desired = target
        lock.unlock()
        pump()
    }

    /// Forget what the daemon is believed to hold, so the desired target is sent
    /// again (daemon restarted, wake from sleep, or the fans stopped following).
    public func invalidate() {
        lock.lock()
        confirmed = nil
        nextAttemptAt = -.infinity
        lock.unlock()
        pump()
    }

    /// Stop sending (another owner, such as a Terminal hold, has the fans).
    public func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        if value { confirmed = nil }
        lock.unlock()
        if !value { pump() }
    }

    /// Re-check retry timers. Call periodically (the monitor tick does).
    public func poll() { pump() }

    private func pump() {
        lock.lock()
        let t = now()
        guard !paused, !inFlight, let target = desired else { lock.unlock(); return }
        if let confirmed, target.isClose(to: confirmed, tolerance: Self.rpmTolerance) {
            lock.unlock(); return
        }
        guard t >= nextAttemptAt else { lock.unlock(); return }
        let modeChange: Bool
        switch (target, confirmed) {
        case (.rpm, .rpm?), (.perFan, .perFan?): modeChange = false
        default: modeChange = true
        }
        guard modeChange || t - lastSendAt >= Self.minimumInterval else { lock.unlock(); return }
        inFlight = true
        lastSendAt = t
        lock.unlock()

        queue.async { [self] in
            var failure: Error?
            do { try perform(target) } catch { failure = error }
            complete(target, error: failure)
        }
    }

    private func complete(_ target: FanTarget, error: Error?) {
        lock.lock()
        inFlight = false
        var newHealth: Health? = nil
        if let error {
            failures += 1
            // 0.5, 1, 2, 4, 8, then every 10 seconds.
            let backoff = min(0.5 * pow(2, Double(failures - 1)), 10)
            nextAttemptAt = now() + backoff
            if failures >= Self.reportAfterFailures {
                let next = Health.retrying(failures: failures, message: "\(error)")
                if next != health { health = next; newHealth = next }
            }
        } else {
            failures = 0
            nextAttemptAt = -.infinity
            if !paused { confirmed = target }
            if health != .ok { health = .ok; newHealth = .ok }
        }
        lock.unlock()

        onAttempt?(target, error)
        if let newHealth { onHealthChange?(newHealth) }
        pump()
    }
}
