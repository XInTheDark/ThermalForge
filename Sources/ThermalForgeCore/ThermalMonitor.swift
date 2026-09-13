//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
//
//  Dual-cadence design:
//  - Thermal tick (100ms): calculate curve, apply ramp governor, write fan speed
//  - Sensor snapshot (configurable, 1s by default): read temperatures and fan state
//  - Monitor tick (2s): process capture, anomaly detection, history logging
//

import Darwin
import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable {
    case setMax
    /// Set maximum speed and keep the daemon from watchdog-resetting it after
    /// the app exits. Only the thermal safety path should emit this command.
    case safetyMax
    case setRPM(Float)
    case setFan(index: Int, rpm: Float)
    case resetAuto
    /// Synchronize the app's configurable safety threshold with the daemon.
    case setSafetyLimit(Float)

    /// A hold keeps fans at a manual setting (so an unsupervised one-shot could
    /// be reverted by the watchdog); resetAuto hands control back and isn't held.
    public var isHold: Bool {
        switch self {
        case .setMax, .safetyMax, .setRPM, .setFan: return true
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

// MARK: - Monitor State

public enum MonitorState: Equatable {
    case idle
    case active(profileName: String)
    case safetyOverride
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let fanControl: ThermalStatusSource
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor")
    private let healthLock = NSLock()
    private var lastSuccessfulTickUptime: UInt64?
    private var sensorFaultLatched = false

    public private(set) var activeProfile: FanProfile
    public private(set) var usingExternalPower = false
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?
    public private(set) var filteredPeakTemp: Float?
    public private(set) var temperatureFilter: TemperatureFilter
    public private(set) var safetyLimitTemp: Float
    public private(set) var isSafetyLockedAtMax: Bool = false

    // MARK: - Tick Timing

    /// Thermal tick interval in seconds. Fan control runs at this rate.
    private var tickInterval: TimeInterval
    /// Full SMC sensor snapshot interval. This is intentionally independent from
    /// the control timer because thermal hardware changes much more slowly than
    /// the ramp governor needs to run.
    private var sensorRefreshInterval: TimeInterval

    private static let monitorInterval: TimeInterval = 2
    private static let uiUpdateInterval: TimeInterval = 0.5
    private var lastSensorReadUptime: UInt64?
    private var lastMonitorUptime: UInt64?
    private var lastUIUpdateUptime: UInt64?
    private var cachedStatus: ThermalStatus?

    // MARK: - Fan State

    private var lastAppliedRPMPercent: Float = 0
    private var fansCurrentlyRunning = false
    private var isRampingDown = false
    private var sustainedAboveCount = 0
    private var batteryProfile: FanProfile
    private var adapterProfile: FanProfile
    private var batteryTransform: FanPercentTransform
    private var adapterTransform: FanPercentTransform
    /// Manual test control pauses profile writes while keeping sensor reads,
    /// health tracking, and emergency handback active.
    private var manualControlActive = false

    // MARK: - Temperature History

    private var tempHistory: [Float] = []

    // MARK: - Anomaly Detection

    /// Tracks temps over 30 seconds (15 readings at 2s monitor cadence)
    private var anomalyHistory: [Float] = []
    private var isCalibrating = false

    // MARK: - Process Buffer

    /// Rolling buffer — captures what was running BEFORE a spike.
    /// 15 snapshots × 2 seconds = 30 seconds of pre-spike history.
    private var processBuffer: [(timestamp: String, processes: String)] = []
    private let isoFormatter = ISO8601DateFormatter()

    /// Call this to suppress anomaly logging during calibration
    public func setCalibrating(_ value: Bool) {
        queue.async { self.isCalibrating = value }
    }
    private var calibration: CalibrationData? = {
        guard let data = CalibrationData.load() else { return nil }
        if let error = data.validationError {
            TFLogger.shared.error("Calibration data rejected: \(error)")
            return nil
        }
        return data
    }()

    /// Called on UI update cadence (every 500ms) with updated status
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    public var onPowerSourceUpdate: ((PowerSourceState) -> Void)?
    public var onSensorFault: ((String) -> Void)?
    public var onSafetyLimitBreached: ((Float, Float) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege)
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(fanControl: ThermalStatusSource, profile: FanProfile = .default,
                batteryProfile: FanProfile? = nil,
                adapterProfile: FanProfile? = nil,
                batteryTransform: FanPercentTransform = .identity,
                adapterTransform: FanPercentTransform = .adapterDefault,
                sensorRefreshInterval: TimeInterval = 1.0,
                controlLoopInterval: TimeInterval = 0.1,
                temperatureFilter: TemperatureFilter = TemperatureFilter(),
                safetyLimitTemp: Float = FanProfile.safetyTempThreshold) {
        self.fanControl = fanControl
        self.activeProfile = profile
        self.batteryProfile = batteryProfile ?? profile
        self.adapterProfile = adapterProfile ?? profile
        self.batteryTransform = batteryTransform
        self.adapterTransform = adapterTransform
        self.tickInterval = max(controlLoopInterval, 0.05)
        self.sensorRefreshInterval = max(sensorRefreshInterval, self.tickInterval)
        self.temperatureFilter = temperatureFilter
        self.safetyLimitTemp = min(max(safetyLimitTemp, 85.0), 115.0)
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval? = nil) {
        stop()
        if let interval {
            tickInterval = max(interval, 0.05)
            sensorRefreshInterval = max(sensorRefreshInterval, tickInterval)
        }
        lastSensorReadUptime = nil
        lastMonitorUptime = nil
        lastUIUpdateUptime = nil
        healthLock.lock()
        lastSuccessfulTickUptime = nil
        healthLock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: tickInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Apply timing preferences without rebuilding the SMC connection. The update
    /// is serialized with ticks so changing a picker cannot race a control decision.
    public func updateIntervals(sensorRefreshInterval: TimeInterval,
                                controlLoopInterval: TimeInterval) {
        queue.async {
            self.tickInterval = max(controlLoopInterval, 0.05)
            self.sensorRefreshInterval = max(sensorRefreshInterval, self.tickInterval)
            self.lastSensorReadUptime = nil
            self.timer?.schedule(deadline: .now(), repeating: self.tickInterval)
        }
    }

    /// Update temperature smoothing filter configuration.
    public func updateTemperatureFilter(enabled: Bool, rampUpWindow: Double, rampDownWindow: Double) {
        queue.async {
            self.temperatureFilter.isEnabled = enabled
            self.temperatureFilter.rampUpWindowSeconds = max(1.0, rampUpWindow)
            self.temperatureFilter.rampDownWindowSeconds = max(1.0, rampDownWindow)
        }
    }

    /// Update safety upper limit temperature threshold.
    public func updateSafetyLimit(_ temp: Float) {
        queue.async {
            self.safetyLimitTemp = min(max(temp, 85.0), 115.0)
        }
    }

    /// Restore a daemon-reported safety latch when the app starts after the
    /// original app instance exited or lost its heartbeat.
    public func restoreSafetyLock() {
        queue.async {
            self.isSafetyLockedAtMax = true
            self.state = .safetyOverride
            self.fansCurrentlyRunning = true
            self.lastAppliedRPMPercent = 1.0
        }
    }

    /// Update the active profile.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            manualControlActive = false
            healthLock.lock()
            sensorFaultLatched = false
            lastSuccessfulTickUptime = nil
            healthLock.unlock()
            isSafetyLockedAtMax = false
            activeProfile = profile
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            isRampingDown = false
            sustainedAboveCount = 0
            lastMonitorUptime = nil
            lastUIUpdateUptime = nil

            temperatureFilter.reset()
            tempHistory.removeAll()
            let loaded = CalibrationData.load()
            if let error = loaded?.validationError {
                TFLogger.shared.error("Calibration data rejected on reload: \(error)")
                calibration = nil
            } else {
                calibration = loaded
            }

            state = .idle
        }
    }

    public func updateProfiles(battery: FanProfile, adapter: FanProfile,
                               batteryTransform: FanPercentTransform,
                               adapterTransform: FanPercentTransform) {
        queue.async {
            self.batteryProfile = battery
            self.adapterProfile = adapter
            self.batteryTransform = batteryTransform
            self.adapterTransform = adapterTransform
            self.activeProfile = self.usingExternalPower ? adapter : battery
            self.lastAppliedRPMPercent = 0
            self.fansCurrentlyRunning = false
            self.sustainedAboveCount = 0
            self.tempHistory.removeAll()
        }
    }

    public func updatePowerSource(_ source: PowerSourceState) {
        queue.async {
            let external = source == .external
            guard external != self.usingExternalPower else { return }
            self.usingExternalPower = external
            self.activeProfile = external ? self.adapterProfile : self.batteryProfile
            self.lastAppliedRPMPercent = 0
            self.sustainedAboveCount = 0
            self.tempHistory.removeAll()
            self.state = .idle
            self.onPowerSourceUpdate?(source)
        }
    }

    /// Pause/resume automatic profile writes for the app's explicit manual test
    /// control. This is serialized with the control queue.
    public func setManualControl(_ active: Bool, onReady: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.manualControlActive = active
            onReady?()
        }
    }

    public var isControlFaultLatched: Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        return sensorFaultLatched
    }

    /// Reapply the active profile after the daemon has restarted and lost its
    /// in-memory hold record. This is never used after an emergency latch.
    public func requestReapply() {
        queue.async {
            self.healthLock.lock()
            let faulted = self.sensorFaultLatched
            self.healthLock.unlock()
            guard !faulted, !self.manualControlActive, !self.isSafetyLockedAtMax else { return }
            self.lastAppliedRPMPercent = 0
            self.fansCurrentlyRunning = false
            self.isRampingDown = false
            self.sustainedAboveCount = 0
            self.temperatureFilter.reset()
            self.state = .idle
        }
    }

    /// The app heartbeat uses this to prove that the control loop itself is still
    /// making progress. A healthy daemon connection alone is insufficient.
    public func hasRecentControlTick(within interval: TimeInterval = 3) -> Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        guard !sensorFaultLatched, let last = lastSuccessfulTickUptime else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return TimeInterval(now - last) / 1_000_000_000 <= interval
    }

    /// Latch control off immediately when another subsystem detects that the
    /// monitor is no longer trustworthy. The latch is cleared only by explicit
    /// user profile selection.
    public func suspendForEmergency(_ reason: String) {
        healthLock.lock()
        guard !sensorFaultLatched else {
            healthLock.unlock()
            return
        }
        sensorFaultLatched = true
        lastSuccessfulTickUptime = nil
        healthLock.unlock()
        TFLogger.shared.error("Thermal control suspended: \(reason)")
        onSensorFault?(reason)
        if !isSafetyLockedAtMax {
            applyCommand(.resetAuto)
        }
    }

    private func triggerSensorFault(_ reason: String) {
        suspendForEmergency(reason)
        state = .idle
    }

    /// Explicit user action to retry after a sensor/control fault.
    public func clearFaultForUserRetry() {
        queue.async {
            self.healthLock.lock()
            self.sensorFaultLatched = false
            self.lastSuccessfulTickUptime = nil
            self.healthLock.unlock()
            self.isSafetyLockedAtMax = false
            self.state = .idle
        }
    }

    /// Stop automatic control after a fan write failed. The app reports this to
    /// the user; no further profile commands are attempted until an explicit retry.
    public func notifyCommandFailure(_ reason: String = "fan command failed") {
        queue.async { self.triggerSensorFault(reason) }
    }

    // MARK: - Polling

    private func tick() {
        healthLock.lock()
        let faulted = sensorFaultLatched
        healthLock.unlock()
        if faulted { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let sensorDue = cachedStatus == nil || elapsedSince(lastSensorReadUptime, now) >= sensorRefreshInterval
        let status: ThermalStatus
        if sensorDue {
            guard let fresh = try? fanControl.status() else {
                triggerSensorFault("sensor snapshot failed")
                return
            }
            cachedStatus = fresh
            lastSensorReadUptime = now
            status = fresh
            updatePowerSource(SystemPowerSource.current)
        } else {
            guard let cachedStatus else { return }
            status = cachedStatus
        }
        latestStatus = status

        guard status.hasUsableSafetyTemperature else {
            triggerSensorFault("no usable CPU/GPU safety sensor was reported")
            return
        }

        // Core peak (CPU/GPU core diodes matching Stats) drives the fan profile curve.
        // Hotspot/junction peak drives the safety floor and emergency watchdog.
        let corePeak = status.nominalPeakTemp
        let timeConstant = isRampingDown ? temperatureFilter.rampDownWindowSeconds : temperatureFilter.rampUpWindowSeconds
        let effectiveTemp = temperatureFilter.update(rawTemp: corePeak, timeConstant: timeConstant, nowUptime: now)
        filteredPeakTemp = effectiveTemp

        let safetyPeak = status.safetyPeakTemp
        let anySensorMax = status.temperatures.values.max() ?? safetyPeak
        if manualControlActive, anySensorMax >= safetyLimitTemp {
            applyCommand(.safetyMax)
            state = .safetyOverride
            isSafetyLockedAtMax = true
            fansCurrentlyRunning = true
            lastAppliedRPMPercent = 1.0
            TFLogger.shared.safety(
                "Safety limit reached during manual testing: \(String(format: "%.1f", anySensorMax))°C ≥ \(Int(safetyLimitTemp))°C — locking fans at max"
            )
            onSafetyLimitBreached?(anySensorMax, safetyLimitTemp)
            emitUpdateIfDue(status: status, now: now)
            markControlTickHealthy(now)
            return
        }

        let monitorDue = elapsedSince(lastMonitorUptime, now) >= Self.monitorInterval
        if monitorDue {
            monitorTick(status: status, maxTemp: corePeak)
            lastMonitorUptime = now
        }

        // If safety failure is latched, keep fans locked at max RPM
        if isSafetyLockedAtMax {
            if state != .safetyOverride || !fansCurrentlyRunning || lastAppliedRPMPercent < 1.0 {
                applyCommand(.safetyMax)
                state = .safetyOverride
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
            }
            emitUpdateIfDue(status: status, now: now)
            markControlTickHealthy(now)
            return
        }

        if manualControlActive {
            emitUpdateIfDue(status: status, now: now)
            markControlTickHealthy(now)
            return
        }

        // --- Parallel Safety Limit & Profile Calculation ---
        let upperLimitDemand: Float = (anySensorMax >= safetyLimitTemp) ? 1.0 : 0.0
        let profileTarget = calculateProfileTargetPercent(status: status, peakTemp: effectiveTemp)

        let delta = upperLimitDemand - profileTarget
        if delta >= 0.10 {
            // Upper limit breached and exceeds profile output by at least 10%:
            // 1. Trigger upper limit (100% fans)
            // 2. Lock at max fan (latched failure)
            // 3. Dispatch alert
            applyCommand(.safetyMax)
            state = .safetyOverride
            isSafetyLockedAtMax = true
            fansCurrentlyRunning = true
            lastAppliedRPMPercent = 1.0
            TFLogger.shared.safety(
                "Upper safety limit breached: \(String(format: "%.1f", anySensorMax))°C ≥ \(Int(safetyLimitTemp))°C " +
                "(profile target: \(Int(profileTarget * 100))%, delta: \(Int(delta * 100))% ≥ 10%) — locking fans at max"
            )
            onSafetyLimitBreached?(anySensorMax, safetyLimitTemp)
            emitUpdateIfDue(status: status, now: now)
            markControlTickHealthy(now)
            return
        } else if anySensorMax >= safetyLimitTemp {
            // Reached safety limit, but profile is already commanding >= 90%
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = .safetyOverride
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                TFLogger.shared.safety("Safety limit reached: \(String(format: "%.1f", anySensorMax))°C — fans maxed")
            }
            emitUpdateIfDue(status: status, now: now)
            markControlTickHealthy(now)
            return
        }

        if state == .safetyOverride && !isSafetyLockedAtMax
            && anySensorMax < safetyLimitTemp - FanProfile.hysteresisDegrees
        {
            state = .idle
        }

        // Sustained trigger: track consecutive ticks above start threshold.
        // Per-profile duration — converted to tick count at runtime.
        let startThreshold = activeProfile.curve.startTemp
        if effectiveTemp >= startThreshold {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        // All profiles use the same data-driven curve path.
        tickCurve(status: status, peakTemp: effectiveTemp, sampleHistory: monitorDue)

        // UI update at slower cadence (every 500ms)
        emitUpdateIfDue(status: status, now: now)
        markControlTickHealthy(now)
    }

    private func markControlTickHealthy(_ now: UInt64) {
        healthLock.lock()
        lastSuccessfulTickUptime = now
        healthLock.unlock()
    }

    private func elapsedSince(_ previous: UInt64?, _ now: UInt64) -> TimeInterval {
        guard let previous else { return .infinity }
        return TimeInterval(now - previous) / 1_000_000_000
    }

    private func emitUpdateIfDue(status: ThermalStatus, now: UInt64) {
        guard elapsedSince(lastUIUpdateUptime, now) >= Self.uiUpdateInterval else { return }
        lastUIUpdateUptime = now
        onUpdate?(status, activeProfile, state)
    }

    // MARK: - Monitor Cadence (every 2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Runs at 2-second intervals to avoid sysctl overhead at 100ms.
    private func monitorTick(status: ThermalStatus, maxTemp: Float) {
        // Rolling process buffer — always capturing, like a security camera
        let currentProcs = captureTopProcesses()
        let ts = isoFormatter.string(from: Date())
        processBuffer.append((timestamp: ts, processes: currentProcs))
        if processBuffer.count > 15 { processBuffer.removeFirst() }

        // Anomaly detection: two tiers
        // Tier 1: instant spike — >5°C between consecutive readings (2 seconds)
        // Tier 2: sustained change — >10°C over 30 seconds
        if !isCalibrating {
            var spikeDetected = false

            // Tier 1: check against previous reading
            if let prevTemp = anomalyHistory.last {
                let instantDelta = maxTemp - prevTemp
                if abs(instantDelta) > 5 {
                    let direction = instantDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Instant \(direction): \(String(format: "%.1f", prevTemp))→\(String(format: "%.1f", maxTemp))°C " +
                        "(\(String(format: "%+.1f", instantDelta))°C in 2s) | " +
                        "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                        "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                }
            }

            // Tier 2: check over 30-second window
            if anomalyHistory.count >= 15 {
                let oldest = anomalyHistory.first!
                let sustainedDelta = maxTemp - oldest
                if abs(sustainedDelta) > 10 {
                    let direction = sustainedDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Sustained \(direction): \(String(format: "%.1f", oldest))→\(String(format: "%.1f", maxTemp))°C " +
                        "(\(String(format: "%+.1f", sustainedDelta))°C in 30s) | " +
                        "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                        "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                    anomalyHistory.removeAll()
                }
            }

            // Dump the rolling buffer on any spike — shows what was running BEFORE
            if spikeDetected {
                TFLogger.shared.info("Pre-spike process history (last \(processBuffer.count * 2)s):")
                for entry in processBuffer {
                    TFLogger.shared.info("  \(entry.timestamp): \(entry.processes)")
                }
            }
        }

        anomalyHistory.append(maxTemp)
        if anomalyHistory.count > 15 { anomalyHistory.removeFirst() }
    }

    // MARK: - Curve-Based Profiles

    /// Calculate the steady target percentage (0.0–1.0) for the active profile without ramp governors.
    public func calculateProfileTargetPercent(status: ThermalStatus, peakTemp: Float) -> Float {
        let curve = activeProfile.curve
        if curve.handsOff { return 0 }
        if curve.alwaysOn { return curve.maxRPMPercent }

        let batteryTemp = status.temperatures.filter { $0.key.hasPrefix("TB") }.values.max()
        let batteryPressure = batteryTemp.map(FanProfile.batteryCoolingTarget) ?? 0

        guard let curveTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) ?? (batteryPressure > 0 ? batteryPressure : nil) else {
            return 0
        }

        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / Float(tickInterval))
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            return 0
        }

        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        var targetPct = curveTarget <= 0.001 ? minRPM / maxRPM : curveTarget

        if let calibrated = calibration?.fanPercentForTemp(peakTemp) { targetPct = calibrated }
        if targetPct > 0, curve.rateOfChangeBoost > 0 {
            let rate = rateOfChange()
            if rate > 0 { targetPct += rate * curve.rateOfChangeBoost }
        }
        if peakTemp >= curve.ceilingTemp { targetPct = curve.maxRPMPercent }

        if batteryTemp != nil, batteryPressure > 0 {
            targetPct = max(targetPct, batteryPressure)
        }

        let transform = usingExternalPower ? adapterTransform : batteryTransform
        targetPct = transform.apply(to: targetPct)

        return min(max(targetPct, 0), curve.maxRPMPercent)
    }

    private func tickCurve(status: ThermalStatus, peakTemp: Float, sampleHistory: Bool) {
        let curve = activeProfile.curve
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317

        // Hands-off profiles: don't control fans, just monitor
        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                isRampingDown = false
                lastAppliedRPMPercent = 0
                state = .idle
            }
            return
        }

        if sampleHistory {
            tempHistory.append(peakTemp)
            if tempHistory.count > 4 { tempHistory.removeFirst() }
        }

        let batteryTemp = status.temperatures.filter { $0.key.hasPrefix("TB") }.values.max()
        let batteryPressure = batteryTemp.map(FanProfile.batteryCoolingTarget) ?? 0
        let curveTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning)

        if curveTarget == nil && batteryPressure <= 0 {
            // Curve says fans should be off
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                isRampingDown = false
                lastAppliedRPMPercent = 0
                state = .idle
                TFLogger.shared.fan("Fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")
            }
            return
        }

        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / Float(tickInterval))
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(activeProfile.name)]")
            }
            return
        }

        var targetPct = calculateProfileTargetPercent(status: status, peakTemp: peakTemp)
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        // Ramp governors — per-profile rates, per-tick amounts
        let rampUp = curve.rampUpPerSec * Float(tickInterval)
        let rampDown = curve.rampDownPerSec * Float(tickInterval)

        if targetPct > lastAppliedRPMPercent {
            isRampingDown = false
            if !curve.instantEngage {
                // Governed ramp-up
                targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
            }
            // instantEngage: skip governor, jump directly to target
        } else if targetPct < lastAppliedRPMPercent {
            isRampingDown = true
            // Ramp-down governor always applies (even for instantEngage profiles)
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        // Apply if changed meaningfully (threshold scaled for 100ms ticks)
        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = .active(profileName: activeProfile.name)
        } else if fansCurrentlyRunning {
            state = .active(profileName: activeProfile.name)
        }
    }

    /// Temperature rate of change in °C per second, smoothed over recent monitor samples.
    private func rateOfChange() -> Float {
        guard tempHistory.count >= 2 else { return 0 }
        let seconds = Float(tempHistory.count - 1) * Float(Self.monitorInterval)
        return (tempHistory.last! - tempHistory.first!) / seconds
    }

    // MARK: - Process Capture

    /// Capture top 5 processes by CPU for anomaly logging
    private func captureTopProcesses() -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return "unavailable" }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [(name: String, cpu: Double)] = []

        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            guard !name.isEmpty, name != "kernel_task" else { continue }
            let cpuPct = Double(proc.kp_proc.p_pctcpu) / 100.0
            if cpuPct > 0.1 {
                results.append((name, cpuPct))
            }
        }

        let top5 = results.sorted { $0.cpu > $1.cpu }.prefix(5)
        if top5.isEmpty { return "idle" }
        return top5.map { "\($0.name)(\(String(format: "%.1f", $0.cpu))%)" }.joined(separator: ", ")
    }

    // MARK: - Helpers

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            TFLogger.shared.error("Fan command failed: \(command) — \(error)")
        }
    }

}
