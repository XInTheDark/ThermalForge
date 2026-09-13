//
//  Profile.swift
//  ThermalForge
//
//  Fan control profiles with proportional temperature curves.
//
//  Each profile defines a curve that maps temperature to fan speed,
//  along with per-profile ramp rates, sustained triggers, and curve shapes.
//
//  Targets are clamped to hardware minimum RPM while control is active.
//  Hysteresis and ramp limits keep the response stable around thresholds.
//

import Foundation

// MARK: - Curve Shape

/// How the profile maps temperature position to fan speed in the proportional zone.
public enum CurveShape: String, Codable, Equatable {
    /// pos * max — direct proportional response
    case linear
    /// pos² * max — quiet start, accelerates with heat
    case easeIn
    /// √pos * max — fast initial response, levels off
    case easeOut
    /// pos²(3-2pos) * max — smooth at both ends
    case sCurve
}

/// Fixed linear adjustment applied to a curve target for a power-source mode.
/// `output = clamp(input * multiplier + shift)`.
public struct FanPercentTransform: Codable, Equatable, Sendable {
    public let shift: Float
    public let multiplier: Float

    public init(shift: Float = 0, multiplier: Float = 1) {
        self.shift = shift
        self.multiplier = multiplier
    }

    public func apply(to percent: Float) -> Float {
        min(max(percent * multiplier + shift, 0), 1)
    }

    public static let identity = FanPercentTransform()
    /// Adapter default: a modest extra fan target where mains power is available.
    public static let adapterDefault = FanPercentTransform(shift: 0.05, multiplier: 1.10)
}

// MARK: - Profile Model

public struct FanProfile: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let curve: Curve

    /// Defines how the profile maps temperature to fan speed.
    public struct Curve: Codable, Equatable {
        /// At or below this temperature, return to Apple auto.
        /// Keep this below startTemp to provide hysteresis.
        public let stopTemp: Float

        /// Above this temperature, fans engage (after sustained trigger is met).
        public let startTemp: Float

        /// Temperature at which fan speed reaches maxRPMPercent.
        /// Ignored when instantEngage is true (binary on/off).
        public let ceilingTemp: Float

        /// Maximum fan speed as fraction of max RPM (0.0–1.0).
        public let maxRPMPercent: Float

        /// If true, this profile doesn't control fans — stays in Apple auto mode.
        public let handsOff: Bool

        /// If true, fans are always at maxRPMPercent regardless of temperature.
        public let alwaysOn: Bool

        /// How temperature maps to fan speed in the proportional zone.
        public let curveShape: CurveShape

        /// Max fan speed increase per second (fraction of max RPM per second).
        /// Ignored when instantEngage is true.
        public let rampUpPerSec: Float

        /// Max fan speed decrease per second (fraction of max RPM per second).
        public let rampDownPerSec: Float

        /// Seconds of sustained temperature above startTemp before fans engage.
        /// Filters transient spikes that resolve on their own.
        public let sustainedTriggerSec: Float

        /// If true, skip ramp-up governor — jump directly to maxRPMPercent.
        /// Ramp-down governor still applies for smooth deceleration.
        public let instantEngage: Bool

        /// Additional fan fraction per °C/sec of rising temperature.
        public let rateOfChangeBoost: Float

        public init(stopTemp: Float = 50, startTemp: Float = 55, ceilingTemp: Float = 70,
                    maxRPMPercent: Float = 0.6, handsOff: Bool = false, alwaysOn: Bool = false,
                    curveShape: CurveShape = .linear, rampUpPerSec: Float = 0.05,
                    rampDownPerSec: Float = 0.025, sustainedTriggerSec: Float = 8,
                    instantEngage: Bool = false, rateOfChangeBoost: Float = 0) {
            self.stopTemp = stopTemp
            self.startTemp = startTemp
            self.ceilingTemp = ceilingTemp
            self.maxRPMPercent = maxRPMPercent
            self.handsOff = handsOff
            self.alwaysOn = alwaysOn
            self.curveShape = curveShape
            self.rampUpPerSec = rampUpPerSec
            self.rampDownPerSec = rampDownPerSec
            self.sustainedTriggerSec = sustainedTriggerSec
            self.instantEngage = instantEngage
            self.rateOfChangeBoost = rateOfChangeBoost
        }

        private enum CodingKeys: String, CodingKey {
            case stopTemp, startTemp, ceilingTemp, maxRPMPercent, handsOff, alwaysOn,
                 curveShape, rampUpPerSec, rampDownPerSec, sustainedTriggerSec,
                 instantEngage, rateOfChangeBoost
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stopTemp = try c.decode(Float.self, forKey: .stopTemp)
            startTemp = try c.decode(Float.self, forKey: .startTemp)
            ceilingTemp = try c.decode(Float.self, forKey: .ceilingTemp)
            maxRPMPercent = try c.decode(Float.self, forKey: .maxRPMPercent)
            handsOff = try c.decode(Bool.self, forKey: .handsOff)
            alwaysOn = try c.decode(Bool.self, forKey: .alwaysOn)
            curveShape = try c.decode(CurveShape.self, forKey: .curveShape)
            rampUpPerSec = try c.decode(Float.self, forKey: .rampUpPerSec)
            rampDownPerSec = try c.decode(Float.self, forKey: .rampDownPerSec)
            sustainedTriggerSec = try c.decode(Float.self, forKey: .sustainedTriggerSec)
            instantEngage = try c.decode(Bool.self, forKey: .instantEngage)
            rateOfChangeBoost = try c.decodeIfPresent(Float.self, forKey: .rateOfChangeBoost) ?? 0
        }

        /// Calculate the target fan speed percentage (0.0–1.0) for a given temperature.
        /// Returns nil if fans should be off (Apple auto).
        /// Returns 0.001 as a signal to keep fans at minimum RPM (hysteresis band).
        public func targetPercent(at temp: Float, fansCurrentlyRunning: Bool) -> Float? {
            // Always-on profiles ignore temperature
            if alwaysOn { return maxRPMPercent }

            // Hands-off profiles don't control fans
            if handsOff { return nil }

            // Below stop threshold and fans not running: stay off
            if temp <= stopTemp && !fansCurrentlyRunning { return nil }

            // In hysteresis band (between stop and start): maintain current state
            if temp > stopTemp && temp < startTemp {
                return fansCurrentlyRunning ? 0.001 : nil // 0.001 signals "keep at minimum"
            }

            // Below stop threshold but fans are running: turn off
            if temp <= stopTemp && fansCurrentlyRunning { return nil }

            // Above start: apply curve shape
            if temp >= startTemp {
                if temp >= ceilingTemp { return maxRPMPercent }

                // Instant engage profiles jump directly to max (no proportional curve up)
                if instantEngage { return maxRPMPercent }

                return displayPercent(at: temp)
            }

            return nil
        }

        /// Approximate steady-state target used by the visual curve preview.
        public func displayPercent(at temp: Float) -> Float {
            guard !handsOff else { return 0 }
            if alwaysOn { return maxRPMPercent }
            guard temp >= startTemp else { return 0 }
            guard ceilingTemp > startTemp else { return maxRPMPercent }
            if instantEngage || temp >= ceilingTemp { return maxRPMPercent }
            let position = min(max((temp - startTemp) / (ceilingTemp - startTemp), 0), 1)
            let shaped: Float
            switch curveShape {
            case .linear: shaped = position
            case .easeIn: shaped = position * position
            case .easeOut: shaped = sqrt(position)
            case .sCurve: shaped = position * position * (3 - 2 * position)
            }
            return shaped * maxRPMPercent
        }
    }

    public init(id: String, name: String, curve: Curve) {
        self.id = id
        self.name = name
        self.curve = curve
    }

    // Legacy support — old profiles used triggers/fanBehavior
    public struct Triggers: Codable, Equatable {
        public let cpuTemp: Float?
        public let gpuTemp: Float?
        public let memPressure: Float?
        public init(cpuTemp: Float? = nil, gpuTemp: Float? = nil, memPressure: Float? = nil) {
            self.cpuTemp = cpuTemp; self.gpuTemp = gpuTemp; self.memPressure = memPressure
        }
    }
    public struct FanBehavior: Codable, Equatable {
        public let mode: Mode
        public let rpmPercent: Float
        public enum Mode: String, Codable, Equatable { case auto, manual }
        public init(mode: Mode, rpmPercent: Float) { self.mode = mode; self.rpmPercent = rpmPercent }
    }
}

// MARK: - Built-in Profiles

extension FanProfile {
    /// Initial ThermalForge curve: smooth like a system curve, but more proactive
    /// to preserve sustained performance and reduce hot cycling.
    public static let `default` = FanProfile(
        id: "default",
        name: "Default",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 92,
                     maxRPMPercent: 1.0, curveShape: .sCurve,
                     rampUpPerSec: 0.12, rampDownPerSec: 0.05,
                     sustainedTriggerSec: 2, rateOfChangeBoost: 0.15)
    )

    /// Central registry for profiles shown in the app and accepted by the CLI.
    /// Add a profile here; no profile-specific monitor branch is needed.
    public static let available: [FanProfile] = [`default`]
    public static let builtIn: [FanProfile] = available

    /// A return-to-system mode, kept separate from the fork's profile registry.
    public static let system = FanProfile(
        id: "system", name: "Apple Auto",
        curve: Curve(maxRPMPercent: 0, handsOff: true)
    )

    /// Resolve saved or legacy ids to the current profile. Deleted historical profiles
    /// deliberately map to Default so old preferences remain usable.
    public static func selectable(id: String?) -> FanProfile {
        guard let id else { return `default` }
        if id == system.id { return system }
        return available.first { $0.id == id } ?? `default`
    }
}

// MARK: - Persistence

extension FanProfile {
    private static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles")
    }

    public func save() throws {
        let dir = Self.profilesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    public static func loadAll() -> [FanProfile] {
        let dir = profilesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            return builtIn
        }

        var profiles = builtIn
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let profile = try? JSONDecoder().decode(FanProfile.self, from: data)
            {
                if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[idx] = profile
                } else {
                    profiles.append(profile)
                }
            }
        }
        return profiles
    }
}

// MARK: - Safety

extension FanProfile {
    /// Hard safety threshold — overrides any profile
    public static let safetyTempThreshold: Float = 105.0
    /// Hysteresis deadband to prevent oscillation
    public static let hysteresisDegrees: Float = 5.0
    /// Conservative battery cooling target: begin increasing fan demand at 38°C
    /// and request full demand by 40°C.
    public static func batteryCoolingTarget(for temperature: Float) -> Float {
        min(max((temperature - 38) / 2, 0), 1)
    }
}
