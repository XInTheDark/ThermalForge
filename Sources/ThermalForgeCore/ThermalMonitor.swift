//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Runs the control loop: reads sensors, steps `FanController`, and hands the
//  resulting fan target to `FanActuator`. Everything runs on one serial queue.
//
//  Two cadences:
//  - Control tick (100 ms by default): controller step, ramp, actuator poll.
//  - Sensor snapshot (1 s by default): SMC temperatures, fan state, power
//    source. Thermal mass changes slowly; the faster tick only smooths ramps.
//  While nothing drives the fans (Apple Auto, a Terminal hold, lost sensors)
//  there is no ramp to smooth, so the loop ticks at the sensor cadence, capped
//  at `idleTickLimit`. Any configuration change wakes it at the control cadence.
//
//  Nothing here latches control off. Sensor loss hands the fans to Apple Auto
//  until readings return; command failures are retried by the actuator.
//

import Foundation

/// What the monitor is doing with the fans.
public enum MonitorMode: Equatable, Sendable {
    /// Following the active profile (Apple Auto when the profile is hands-off).
    case automatic
    /// Holding a user-chosen manual level for every fan (0…1 of each fan's range).
    case manual(level: Float)
    /// Another owner (a Terminal hold) has the fans; send nothing.
    case paused
}

/// Everything the UI needs from one control tick.
public struct MonitorSnapshot: Sendable {
    public let status: ThermalStatus
    public let profile: FanProfile
    public let mode: MonitorMode
    /// Nil while paused or when no controller output exists yet.
    public let output: ControlOutput?
    public let target: FanTarget?
    public let pressure: ThermalPressure
    public let externalPower: Bool
    /// Set while sensor readings are unusable and Apple Auto has the fans.
    public let sensorIssue: String?
    public let safetyOverride: Bool
    /// Smoothed control temperature, or the raw core peak when unavailable.
    public let controlTemp: Float
}

public final class ThermalMonitor: @unchecked Sendable {
    private let source: ThermalStatusSource
    private let actuator: FanActuator
    private let pressureProvider: @Sendable () -> ThermalPressure
    private let powerProvider: @Sendable () -> PowerSourceState
    private let clock: @Sendable () -> TimeInterval
    private let queue = DispatchQueue(label: "com.thermalforge.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// The timer's current period.
    private var tickInterval: TimeInterval

    // Queue-confined state.
    private var controller: FanController
    private var batteryProfile: FanProfile
    private var adapterProfile: FanProfile
    private var appleAuto: Bool
    private var mode: MonitorMode = .automatic
    private var controlInterval: TimeInterval
    private var sensorInterval: TimeInterval
    private var lastTick: TimeInterval?
    private var lastSensorRead: TimeInterval?
    private var lastSnapshotAt: TimeInterval?
    private var lastGoodStatusAt: TimeInterval?
    private var firstReadAttempt: TimeInterval?
    private var status: ThermalStatus?
    private var externalPower = false
    private var pressure: ThermalPressure = .nominal
    private var sensorIssue: String?
    private var lastOutput: ControlOutput?
    private var lastTarget: FanTarget?
    private var mismatchSeconds: TimeInterval = 0
    private var mismatchLogged = false
    private var lastLoggedDriver: ControlDriver?

    private let healthLock = NSLock()
    private var lastTickUptime: TimeInterval?

    /// Sensor readings may fail this long before Apple Auto takes over.
    static let sensorGraceSeconds: TimeInterval = 5
    /// Fans must disagree with the confirmed target this long before a resend.
    static let mismatchSeconds: TimeInterval = 4
    static let mismatchToleranceRPM = 150
    static let snapshotInterval: TimeInterval = 0.5
    /// Longest idle tick. Keeps the app heartbeat's loop-health check fresh.
    static let idleTickLimit: TimeInterval = 1
    /// A sensor read due within this margin happens on the current tick, so
    /// timer jitter cannot push a read to the next (possibly idle) tick.
    static let sensorReadMargin: TimeInterval = 0.05

    /// Called on the monitor queue about twice a second.
    public var onSnapshot: (@Sendable (MonitorSnapshot) -> Void)?

    public init(source: ThermalStatusSource,
                actuator: FanActuator,
                batteryProfile: FanProfile = .default,
                adapterProfile: FanProfile = .default,
                appleAuto: Bool = false,
                settings: ControlSettings = ControlSettings(),
                sensorRefreshInterval: TimeInterval = 1.0,
                controlLoopInterval: TimeInterval = 0.1,
                pressureProvider: @escaping @Sendable () -> ThermalPressure = { ThermalPressure.current },
                powerProvider: @escaping @Sendable () -> PowerSourceState = { SystemPowerSource.current },
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source
        self.actuator = actuator
        self.batteryProfile = batteryProfile
        self.adapterProfile = adapterProfile
        self.appleAuto = appleAuto
        self.pressureProvider = pressureProvider
        self.powerProvider = powerProvider
        self.clock = clock
        self.controlInterval = max(controlLoopInterval, 0.05)
        self.sensorInterval = max(sensorRefreshInterval, max(controlLoopInterval, 0.05))
        self.tickInterval = self.controlInterval
        self.controller = FanController(profile: appleAuto ? .system : batteryProfile, settings: settings)
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [self] in
            timer?.cancel()
            lastTick = nil
            lastSensorRead = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            wake()
            timer.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Run one tick synchronously (tests and diagnostics).
    public func tickNow() {
        queue.sync { tick() }
    }

    // MARK: - Configuration (all serialized with ticks)

    public func updateIntervals(sensorRefreshInterval: TimeInterval, controlLoopInterval: TimeInterval) {
        queue.async { [self] in
            controlInterval = max(controlLoopInterval, 0.05)
            sensorInterval = max(sensorRefreshInterval, controlInterval)
            lastSensorRead = nil
            wake()
        }
    }

    public func updateSettings(_ settings: ControlSettings) {
        queue.async { [self] in
            controller.setSettings(settings)
            wake()
        }
    }

    /// Set the battery and adapter profiles, or Apple Auto.
    public func updateProfiles(battery: FanProfile, adapter: FanProfile, appleAuto: Bool) {
        queue.async { [self] in
            batteryProfile = battery
            adapterProfile = adapter
            self.appleAuto = appleAuto
            applyActiveProfile()
            wake()
        }
    }

    public func setMode(_ mode: MonitorMode) {
        queue.async { [self] in
            guard self.mode != mode else { return }
            let wasPaused = self.mode == .paused
            self.mode = mode
            actuator.setPaused(mode == .paused)
            if wasPaused { actuator.invalidate() }
            wake()
        }
    }

    /// After sleep or a daemon restart: forget smoothing history and resend.
    public func resync(resetHistory: Bool) {
        queue.async { [self] in
            if resetHistory { controller.reset() }
            mismatchSeconds = 0
            actuator.invalidate()
            wake()
        }
    }

    /// The timer period: the control cadence while driving the fans, longer while idle.
    var currentTickInterval: TimeInterval { queue.sync { tickInterval } }

    /// The app heartbeat uses this to prove the loop is still making progress.
    public func hasRecentTick(within interval: TimeInterval = 3) -> Bool {
        healthLock.lock(); defer { healthLock.unlock() }
        guard let last = lastTickUptime else { return false }
        return clock() - last <= interval
    }

    // MARK: - Tick

    private func tick() {
        let now = clock()
        let dt = lastTick.map { now - $0 } ?? controlInterval
        lastTick = now
        healthLock.lock(); lastTickUptime = now; healthLock.unlock()

        if lastSensorRead == nil || now - lastSensorRead! >= sensorInterval - Self.sensorReadMargin {
            readSensors(now: now)
        }
        defer { setTickInterval(drivingFans ? controlInterval : idleInterval) }

        guard let status, sensorIssue == nil else {
            // No trustworthy readings: Apple Auto has the fans until they return.
            if mode != .paused { actuator.request(.system) }
            lastTarget = mode == .paused ? nil : .system
            lastOutput = nil
            actuator.poll()
            emitSnapshot(now: now)
            return
        }

        let input = controlInput(from: status)
        let target: FanTarget?
        switch mode {
        case .paused:
            target = nil
            lastOutput = nil
        case .manual(let level):
            let safety = controller.stepSafetyOnly(hotspotTemp: input.hotspotTemp, dt: dt)
            lastOutput = nil
            if safety, let range = status.controlRange {
                target = .rpm(Int(range.max.rounded()))
            } else {
                target = status.perFanTarget(level: level)
            }
        case .automatic:
            let output = controller.step(input, dt: dt)
            lastOutput = output
            logTransitions(output, input: input)
            if output.engaged, let range = status.controlRange {
                let rpm = range.min + output.level * (range.max - range.min)
                target = .rpm(Int((rpm / 10).rounded() * 10))
            } else {
                target = .system
            }
        }

        lastTarget = target
        if let target { actuator.request(target) }
        actuator.poll()
        emitSnapshot(now: now)
    }

    // MARK: - Cadence

    /// A fan target other than Apple Auto is being held, so ramps need the control cadence.
    private var drivingFans: Bool {
        switch lastTarget {
        case .rpm?, .perFan?: return true
        case .system?, nil: return false
        }
    }

    private var idleInterval: TimeInterval {
        max(controlInterval, min(sensorInterval, Self.idleTickLimit))
    }

    /// Tick right away at the control cadence; that tick settles the cadence again.
    private func wake() {
        tickInterval = controlInterval
        timer?.schedule(deadline: .now(), repeating: controlInterval, leeway: Self.leeway(controlInterval))
    }

    private func setTickInterval(_ interval: TimeInterval) {
        guard interval != tickInterval else { return }
        tickInterval = interval
        timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: Self.leeway(interval))
    }

    /// Leeway lets macOS coalesce the wakeups with other work.
    private static func leeway(_ interval: TimeInterval) -> DispatchTimeInterval {
        .milliseconds(Int(min(interval / 2, 0.25) * 1000))
    }

    // MARK: - Sensors

    private func readSensors(now: TimeInterval) {
        let elapsed = now - (lastSensorRead ?? now)
        lastSensorRead = now
        if firstReadAttempt == nil { firstReadAttempt = now }

        let previousPower = externalPower
        externalPower = powerProvider() == .external
        if externalPower != previousPower {
            if lastGoodStatusAt != nil {
                TFLogger.shared.info("Power source: \(externalPower ? "adapter" : "battery")")
            }
            applyActiveProfile()
        }
        let newPressure = pressureProvider()
        if newPressure != pressure {
            TFLogger.shared.info("macOS thermal pressure: \(pressure) → \(newPressure)")
            pressure = newPressure
        }

        if let fresh = try? source.status(), fresh.isUsableForControl {
            status = fresh
            lastGoodStatusAt = now
            if let issue = sensorIssue {
                TFLogger.shared.info("Sensors recovered after \(issue) — resuming control")
                sensorIssue = nil
                controller.reset()
            }
            verifyFansFollow(fresh, elapsed: elapsed)
            return
        }

        // A failed or implausible read keeps the last good snapshot for a short
        // grace period; only a sustained loss hands the fans to Apple Auto.
        guard sensorIssue == nil, let failingSince = lastGoodStatusAt ?? firstReadAttempt,
              now - failingSince >= Self.sensorGraceSeconds else { return }
        sensorIssue = "temperature sensors stopped reporting"
        TFLogger.shared.error("Sensor readings unavailable — Apple Auto has the fans until they recover")
    }

    /// Resend when the fans run slower than a target the daemon accepted —
    /// e.g. macOS reclaimed fan control after wake. A target held *higher* than
    /// ours (macOS or another app adding cooling) is left alone: fighting it
    /// would only make the fans hunt.
    private func verifyFansFollow(_ status: ThermalStatus, elapsed: TimeInterval) {
        guard mode != .paused, let confirmed = actuator.confirmedTarget, confirmed == lastTarget else {
            mismatchSeconds = 0
            return
        }
        let expected: [Int]
        switch confirmed {
        case .system: mismatchSeconds = 0; return
        case .rpm(let rpm): expected = Array(repeating: rpm, count: status.fans.count)
        case .perFan(let rpms): expected = rpms
        }
        let following = zip(status.fans, expected).allSatisfy { fan, rpm in
            fan.targetRPM >= rpm - Self.mismatchToleranceRPM
        }
        if following {
            mismatchSeconds = 0
            mismatchLogged = false
            return
        }
        mismatchSeconds += elapsed
        if mismatchSeconds >= Self.mismatchSeconds {
            if !mismatchLogged {
                TFLogger.shared.info("Fans are not following \(confirmed) (target reads \(status.fans.map(\.targetRPM))) — resending")
                mismatchLogged = true
            }
            mismatchSeconds = 0
            actuator.invalidate()
        }
    }

    private func controlInput(from status: ThermalStatus) -> ControlInput {
        ControlInput(coreTemp: status.nominalPeakTemp,
                            hotspotTemp: status.safetyPeakTemp,
                            batteryTemp: status.batteryTemp,
                            pressure: pressure,
                            externalPower: externalPower,
                            currentLevel: status.actualLevel)
    }

    private func applyActiveProfile() {
        let profile = appleAuto ? FanProfile.system : (externalPower ? adapterProfile : batteryProfile)
        if profile != controller.profile {
            controller.setProfile(profile)
        }
    }

    private func logTransitions(_ output: ControlOutput, input: ControlInput) {
        let driver = output.driver
        defer { lastLoggedDriver = driver }
        guard let previous = lastLoggedDriver, previous != driver else { return }
        let temps = String(format: "core %.1f°C (smoothed %.1f°C), hotspot %.1f°C",
                           input.coreTemp, output.filteredTemp, input.hotspotTemp)
        switch (previous, driver) {
        case (_, .safety):
            TFLogger.shared.safety("Hotspot at or above \(Int(controller.settings.safetyLimit))°C — full fan speed (\(temps))")
        case (.safety, _):
            TFLogger.shared.safety("Hotspot cooled — leaving full speed (\(temps))")
        case (.appleAuto, _):
            TFLogger.shared.fan("Taking over from Apple Auto [\(controller.profile.name)] — \(temps)")
        case (_, .appleAuto):
            TFLogger.shared.fan("Handing fans back to Apple Auto [\(controller.profile.name)] — \(temps)")
        default:
            break
        }
    }

    private func emitSnapshot(now: TimeInterval) {
        guard let status, let onSnapshot else { return }
        if let last = lastSnapshotAt, now - last < Self.snapshotInterval { return }
        lastSnapshotAt = now
        let snapshot = MonitorSnapshot(
            status: status,
            profile: controller.profile,
            mode: mode,
            output: lastOutput,
            target: lastTarget,
            pressure: pressure,
            externalPower: externalPower,
            sensorIssue: sensorIssue,
            safetyOverride: lastOutput?.safetyOverride ?? false,
            controlTemp: controller.smoothedTemp ?? status.nominalPeakTemp
        )
        onSnapshot(snapshot)
    }
}
