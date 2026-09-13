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
    case setRPM(Float)
    case setFan(index: Int, rpm: Float)
    case resetAuto

    /// A hold keeps fans at a manual setting (so an unsupervised one-shot could
    /// be reverted by the watchdog); resetAuto hands control back and isn't held.
    public var isHold: Bool {
        switch self {
        case .setMax, .setRPM, .setFan: return true
        case .resetAuto: return false
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
    private let fanControl: FanControl
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor")

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

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
    private var sustainedAboveCount = 0

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
    /// Called when a fan command needs to be executed (may require privilege)
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(fanControl: FanControl, profile: FanProfile = .default,
                sensorRefreshInterval: TimeInterval = 1.0,
                controlLoopInterval: TimeInterval = 0.1) {
        self.fanControl = fanControl
        self.activeProfile = profile
        self.tickInterval = max(controlLoopInterval, 0.05)
        self.sensorRefreshInterval = max(sensorRefreshInterval, self.tickInterval)
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

    /// Update the active profile.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            activeProfile = profile
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            sustainedAboveCount = 0
            lastMonitorUptime = nil
            lastUIUpdateUptime = nil

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

    // MARK: - Polling

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let sensorDue = cachedStatus == nil || elapsedSince(lastSensorReadUptime, now) >= sensorRefreshInterval
        let status: ThermalStatus
        if sensorDue {
            guard let fresh = try? fanControl.status() else { return }
            cachedStatus = fresh
            lastSensorReadUptime = now
            status = fresh
        } else {
            guard let cachedStatus else { return }
            status = cachedStatus
        }
        latestStatus = status

        // Peak CPU (TC/Tp) + GPU (TG/Tg) — the shared safety-floor sensor extraction,
        // so the client monitor and the daemon's floor read the identical value.
        let maxTemp = status.safetyPeakTemp

        let monitorDue = elapsedSince(lastMonitorUptime, now) >= Self.monitorInterval
        if monitorDue {
            monitorTick(status: status, maxTemp: maxTemp)
            lastMonitorUptime = now
        }

        // Safety override: any sensor > 95°C
        if maxTemp >= FanProfile.safetyTempThreshold {
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = .safetyOverride
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", maxTemp))°C — fans maxed")
            }
            emitUpdateIfDue(status: status, now: now)
            return
        }

        // Clear safety override with hysteresis
        if state == .safetyOverride
            && maxTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            state = .idle
        }

        // Sustained trigger: track consecutive ticks above start threshold.
        // Per-profile duration — converted to tick count at runtime.
        let startThreshold = activeProfile.curve.startTemp
        if maxTemp >= startThreshold {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        // All profiles use the same data-driven curve path.
        tickCurve(status: status, peakTemp: maxTemp, sampleHistory: monitorDue)

        // UI update at slower cadence (every 500ms)
        emitUpdateIfDue(status: status, now: now)
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

    private func tickCurve(status: ThermalStatus, peakTemp: Float, sampleHistory: Bool) {
        let curve = activeProfile.curve
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317

        // Hands-off profiles: don't control fans, just monitor
        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = .idle
            }
            return
        }

        if sampleHistory {
            tempHistory.append(peakTemp)
            if tempHistory.count > 4 { tempHistory.removeFirst() }
        }

        // Get target from the shared curve math.
        guard let rawTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) else {
            // Curve says fans should be off
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = .idle
                TFLogger.shared.fan("Fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")
            }
            return
        }

        // Sustained trigger: per-profile duration.
        // Converted to tick count at runtime based on tick interval.
        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / Float(tickInterval))
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(activeProfile.name)]")
            }
            return
        }

        // 0.001 signals "keep at minimum" (hysteresis band)
        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget
        if let calibrated = calibration?.fanPercentForTemp(peakTemp) { targetPct = calibrated }
        if targetPct > 0, curve.rateOfChangeBoost > 0 {
            let rate = rateOfChange()
            if rate > 0 { targetPct += rate * curve.rateOfChangeBoost }
        }
        if peakTemp >= curve.ceilingTemp { targetPct = curve.maxRPMPercent }

        // Clamp to valid range
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        // Ramp governors — per-profile rates, per-tick amounts
        let rampUp = curve.rampUpPerSec * Float(tickInterval)
        let rampDown = curve.rampDownPerSec * Float(tickInterval)

        if targetPct > lastAppliedRPMPercent {
            if !curve.instantEngage {
                // Governed ramp-up
                targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
            }
            // instantEngage: skip governor, jump directly to target
        } else if targetPct < lastAppliedRPMPercent {
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
