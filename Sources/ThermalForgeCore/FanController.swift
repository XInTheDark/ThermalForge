//
//  FanController.swift
//  ThermalForge
//
//  The control law, kept free of timers, SMC, and sockets so every decision is
//  deterministic and unit-testable. `ThermalMonitor` feeds it sensor readings
//  and turns its output into fan commands.
//
//  Each step:
//   1. Smooth the core temperature (fast attack, slow decay).
//   2. Decide whether ThermalForge controls the fans or leaves them to Apple
//      Auto (engage/release with temperature and time hysteresis).
//   3. Build a demand from the profile curve plus a rising-temperature boost
//      and a slow sustained-load trim, then apply the power-source transform.
//   4. Raise the demand to the battery, macOS thermal-pressure, and hotspot
//      safety floors.
//   5. Move the commanded level toward the demand within the profile's ramp
//      limits (safety and critical pressure bypass the ramp-up limit).
//

import Foundation

/// macOS thermal pressure, as reported by `ProcessInfo.thermalState`. macOS
/// raises it when it starts limiting performance to manage heat.
public enum ThermalPressure: Int, Comparable, Sendable, CustomStringConvertible {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public static var current: ThermalPressure { ThermalPressure(ProcessInfo.processInfo.thermalState) }

    /// Minimum fan level while macOS reports this pressure.
    public var floorLevel: Float {
        switch self {
        case .nominal: return 0
        case .fair: return 0.30
        case .serious: return 0.80
        case .critical: return 1
        }
    }

    public static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

/// User settings that apply to every profile.
public struct ControlSettings: Equatable, Sendable {
    /// Hand control back to Apple Auto (fans may stop) when the machine is cool.
    /// When false, ThermalForge keeps the fans at least at minimum RPM.
    public var handBackWhenCool: Bool = true
    /// Overrides the profile's takeover temperature. The release temperature
    /// moves with it, keeping the profile's hysteresis gap.
    public var takeoverTemp: Float?
    /// Silicon hotspot limit for the full-speed safety override.
    public var safetyLimit: Float = FanProfile.safetyTempThreshold
    public var batteryTransform: FanPercentTransform = .identity
    public var adapterTransform: FanPercentTransform = .adapterDefault
    public var filter = TemperatureFilter()

    public init(handBackWhenCool: Bool = true, takeoverTemp: Float? = nil,
                safetyLimit: Float = FanProfile.safetyTempThreshold,
                batteryTransform: FanPercentTransform = .identity,
                adapterTransform: FanPercentTransform = .adapterDefault,
                filter: TemperatureFilter = TemperatureFilter()) {
        self.handBackWhenCool = handBackWhenCool
        self.takeoverTemp = takeoverTemp
        self.safetyLimit = safetyLimit
        self.batteryTransform = batteryTransform
        self.adapterTransform = adapterTransform
        self.filter = filter
    }

    /// Takeover and hand-back temperatures for a profile under these settings.
    public func thresholds(for curve: FanProfile.Curve) -> (engage: Float, release: Float) {
        guard let takeoverTemp else { return (curve.engageTemp, curve.releaseTemp) }
        let gap = max(curve.engageTemp - curve.releaseTemp, 2)
        return (takeoverTemp, takeoverTemp - gap)
    }
}

/// One sensor reading for the controller.
public struct ControlInput: Equatable, Sendable {
    /// Hottest nominal CPU/GPU core diode, °C.
    public var coreTemp: Float
    /// Hottest CPU/GPU/SoC silicon sensor including hotspots, °C.
    public var hotspotTemp: Float
    public var batteryTemp: Float?
    public var pressure: ThermalPressure
    public var externalPower: Bool
    /// Current fan speed as a level, for a smooth takeover from Apple Auto.
    public var currentLevel: Float?

    public init(coreTemp: Float, hotspotTemp: Float, batteryTemp: Float? = nil,
                pressure: ThermalPressure = .nominal, externalPower: Bool = false,
                currentLevel: Float? = nil) {
        self.coreTemp = coreTemp
        self.hotspotTemp = hotspotTemp
        self.batteryTemp = batteryTemp
        self.pressure = pressure
        self.externalPower = externalPower
        self.currentLevel = currentLevel
    }
}

/// What is currently setting the fan level — shown in the menu bar.
public enum ControlDriver: String, Equatable, Sendable {
    case appleAuto      // Apple Auto, ThermalForge not controlling
    case standby        // controlling at minimum while cool (hand-back disabled or pending)
    case curve          // the profile curve
    case rising         // rising-temperature boost
    case sustained      // sustained-load trim
    case battery        // battery temperature floor
    case pressure       // macOS thermal-pressure floor
    case safety         // hotspot safety override
}

public struct ControlOutput: Equatable, Sendable {
    /// True when ThermalForge controls the fans; false means Apple Auto.
    public var engaged: Bool
    /// Commanded fan level after ramp limits, 0…1.
    public var level: Float
    /// Fan level the controller is moving toward.
    public var demand: Float
    public var filteredTemp: Float
    public var driver: ControlDriver
    public var safetyOverride: Bool
    public var sustainedTrim: Float
}

public struct FanController: Sendable {
    public private(set) var profile: FanProfile
    public private(set) var settings: ControlSettings

    private var filter: TemperatureFilter
    private var previousFiltered: Float?
    private var riseRate: Float = 0
    private var engaged = false
    private var level: Float = 0
    private var trim: Float = 0
    private var aboveEngageFor: Double = 0
    private var belowReleaseFor: Double = 0
    private var safetyOverride = false
    private var hotFor: Double = 0
    private var coolFor: Double = 0

    // Tuning constants shared by every profile.
    /// Hotspot readings must stay at or above the limit this long before the
    /// override engages, so a single-sample spike never maxes the fans.
    static let safetyConfirmSeconds: Double = 2
    /// The override clears after the hotspot stays below `limit - margin` this long.
    static let safetyClearSeconds: Double = 10
    /// Sustained-load trim gain: level per (°C above target × second).
    static let trimGain: Float = 0.0025
    /// Trim decay once the temperature is comfortably below target, per second.
    static let trimDecayPerSec: Float = 0.01
    static let maxTrim: Float = 0.40
    static let maxRiseBoost: Float = 0.15
    /// Rising rates below this (°C/s) are treated as noise.
    static let riseDeadband: Float = 0.1
    static let riseRateSeconds: Double = 5

    public init(profile: FanProfile, settings: ControlSettings = ControlSettings()) {
        self.profile = profile
        self.settings = settings
        self.filter = settings.filter
    }

    public var isEngaged: Bool { engaged }
    public var smoothedTemp: Float? { filter.filteredValue }

    /// Switch profile. Smoothing history is kept (the hardware didn't change);
    /// the commanded level carries over so the switch is smooth.
    public mutating func setProfile(_ profile: FanProfile) {
        self.profile = profile
        trim = 0
        aboveEngageFor = 0
        belowReleaseFor = 0
        if profile.curve.handsOff {
            engaged = false
            level = 0
        }
    }

    public mutating func setSettings(_ settings: ControlSettings) {
        let filterChanged = settings.filter.isEnabled != self.settings.filter.isEnabled
        self.settings = settings
        filter.isEnabled = settings.filter.isEnabled
        filter.attackSeconds = settings.filter.attackSeconds
        filter.decaySeconds = settings.filter.decaySeconds
        if filterChanged { filter.reset() }
    }

    /// Forget all history (sensor recovery, wake from sleep, explicit retry).
    public mutating func reset() {
        filter.reset()
        previousFiltered = nil
        riseRate = 0
        engaged = false
        level = 0
        trim = 0
        aboveEngageFor = 0
        belowReleaseFor = 0
        safetyOverride = false
        hotFor = 0
        coolFor = 0
    }

    public mutating func step(_ input: ControlInput, dt rawDt: Double) -> ControlOutput {
        let dt = min(max(rawDt, 0), 5)
        let curve = profile.curve

        // 1. Smoothing and rate of rise.
        let filtered = filter.update(rawTemp: input.coreTemp, dt: dt)
        if let previousFiltered, dt > 0 {
            let instantaneous = (filtered - previousFiltered) / Float(dt)
            let alpha = Float(1 - exp(-dt / Self.riseRateSeconds))
            riseRate += alpha * (instantaneous - riseRate)
        }
        previousFiltered = filtered

        // 2. Hotspot safety override.
        updateSafety(hotspotTemp: input.hotspotTemp, dt: dt)

        if curve.handsOff {
            engaged = false
            level = 0
            trim = 0
            return ControlOutput(engaged: false, level: 0, demand: 0, filteredTemp: filtered,
                                 driver: .appleAuto, safetyOverride: false, sustainedTrim: 0)
        }

        // 3. Constraints that apply regardless of the curve.
        let batteryDemand = input.batteryTemp.map(FanProfile.batteryCoolingTarget) ?? 0
        let pressureFloor = input.pressure.floorLevel
        let forced = safetyOverride || pressureFloor > 0 || batteryDemand > 0

        // 4. Engage / release.
        let (engageAt, releaseAt) = settings.thresholds(for: curve)
        aboveEngageFor = filtered >= engageAt ? aboveEngageFor + dt : 0
        belowReleaseFor = filtered <= releaseAt && !forced ? belowReleaseFor + dt : 0
        if !engaged {
            if !settings.handBackWhenCool || forced || aboveEngageFor >= Double(curve.engageDelay) {
                engaged = true
                trim = 0
                // Take over at the speed Apple Auto was already running, then
                // move toward the curve, so a takeover never drops the fans.
                level = min(max(input.currentLevel ?? 0, 0), 1)
            }
        } else if settings.handBackWhenCool, belowReleaseFor >= Double(curve.releaseDelay), level <= 0.001 {
            engaged = false
            trim = 0
        }

        guard engaged else {
            return ControlOutput(engaged: false, level: 0, demand: 0, filteredTemp: filtered,
                                 driver: .appleAuto, safetyOverride: false, sustainedTrim: 0)
        }

        // 5. Profile demand with rising boost and sustained trim.
        let base = curve.level(at: filtered)
        let boost = min(max(riseRate - Self.riseDeadband, 0) * curve.riseBoost, Self.maxRiseBoost)
        if filtered > curve.targetTemp, level < 1 {
            trim += Self.trimGain * (filtered - curve.targetTemp) * Float(dt)
        } else if filtered < curve.targetTemp - 2 {
            trim -= Self.trimDecayPerSec * Float(dt)
        }
        trim = min(max(trim, 0), Self.maxTrim)

        let profileDemand = min(base + boost + trim, 1)
        let transform = input.externalPower ? settings.adapterTransform : settings.batteryTransform
        var demand = transform.apply(to: max(profileDemand, batteryDemand))
        demand = max(demand, pressureFloor)
        if safetyOverride { demand = 1 }

        // 6. Ramp limits.
        let instant = safetyOverride || input.pressure == .critical
        if demand > level {
            level = instant ? demand : min(demand, level + curve.rampUpPerSec * Float(dt))
        } else if demand < level {
            level = max(demand, level - curve.rampDownPerSec * Float(dt))
        }

        let driver: ControlDriver
        if safetyOverride {
            driver = .safety
        } else if pressureFloor > 0, pressureFloor >= transform.apply(to: max(profileDemand, batteryDemand)) {
            driver = .pressure
        } else if batteryDemand > profileDemand {
            driver = .battery
        } else if trim >= 0.02, trim >= boost {
            driver = .sustained
        } else if boost >= 0.02 {
            driver = .rising
        } else if base <= 0, level <= 0.001 {
            driver = .standby
        } else {
            driver = .curve
        }

        return ControlOutput(engaged: true, level: level, demand: demand, filteredTemp: filtered,
                             driver: driver, safetyOverride: safetyOverride, sustainedTrim: trim)
    }

    /// Like `step`, but only evaluates the hotspot safety override. Used while
    /// the user holds a manual fan speed.
    public mutating func stepSafetyOnly(hotspotTemp: Float, dt rawDt: Double) -> Bool {
        updateSafety(hotspotTemp: hotspotTemp, dt: min(max(rawDt, 0), 5))
        return safetyOverride
    }

    /// Non-latching override, debounced both ways: it engages after the hotspot
    /// stays at the limit for `safetyConfirmSeconds` and clears after it stays
    /// `safetyClearMargin` below the limit for `safetyClearSeconds`.
    private mutating func updateSafety(hotspotTemp: Float, dt: Double) {
        let limit = settings.safetyLimit
        hotFor = hotspotTemp >= limit ? hotFor + dt : 0
        coolFor = hotspotTemp <= limit - FanProfile.safetyClearMargin ? coolFor + dt : 0
        if !safetyOverride, hotFor >= Self.safetyConfirmSeconds { safetyOverride = true }
        if safetyOverride, coolFor >= Self.safetyClearSeconds { safetyOverride = false }
    }
}
