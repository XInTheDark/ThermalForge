//
//  Profile.swift
//  ThermalForge
//
//  Fan profiles: what fan level each temperature calls for, and how quickly
//  the controller may take over, move, and hand back.
//
//  A fan *level* is a position in the fan's own hardware range: 0 is the
//  minimum spinning RPM and 1 is the maximum. The manual control and the menu
//  bar percentages use the same scale, so 40% means the same thing everywhere.
//
//  The curve is evaluated against the smoothed CPU/GPU core temperature. The
//  live result also depends on the sustained-load trim, rising-temperature
//  boost, battery and macOS thermal-pressure floors, ramp limits, and safety
//  override applied by `FanController`.
//

import Foundation

/// Fixed linear adjustment applied to a profile's fan level for a power-source
/// mode. `output = clamp(input * multiplier + shift)`. Applied only to a positive
/// demand so that "minimum RPM" stays minimum on either power source.
public struct FanPercentTransform: Codable, Equatable, Sendable {
    public let shift: Float
    public let multiplier: Float

    public init(shift: Float = 0, multiplier: Float = 1) {
        self.shift = shift
        self.multiplier = multiplier
    }

    public func apply(to level: Float) -> Float {
        guard level > 0 else { return 0 }
        return min(max(level * multiplier + shift, 0), 1)
    }

    public static let identity = FanPercentTransform()
    /// Adapter default: a modest extra fan level where mains power is available.
    public static let adapterDefault = FanPercentTransform(shift: 0.05, multiplier: 1.10)
}

// MARK: - Profile Model

public struct FanProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// One-line description shown in the profile picker.
    public let summary: String
    public let curve: Curve

    public struct Curve: Codable, Equatable, Sendable {
        public struct Point: Codable, Equatable, Sendable {
            /// Smoothed core temperature, °C.
            public let temp: Float
            /// Fan level, 0 (minimum RPM) … 1 (maximum RPM).
            public let level: Float

            public init(_ temp: Float, _ level: Float) {
                self.temp = temp
                self.level = level
            }
        }

        /// Temperature → fan level, ascending by temperature. Linear between
        /// points; flat beyond the first and last point.
        public let points: [Point]
        /// ThermalForge takes over from Apple Auto once the smoothed core
        /// temperature stays at or above this for `engageDelay` seconds.
        public let engageTemp: Float
        /// Control returns to Apple Auto once the smoothed core temperature stays
        /// at or below this for `releaseDelay` seconds and the fans have ramped
        /// down to minimum. Keep it below `engageTemp` for hysteresis.
        public let releaseTemp: Float
        public let engageDelay: Float
        public let releaseDelay: Float
        /// Sustained-load target. While the smoothed temperature stays above it,
        /// a slow trim adds fan level until the temperature comes back down, so a
        /// long workload settles near this temperature instead of creeping up.
        public let targetTemp: Float
        /// Maximum fan level change per second.
        public let rampUpPerSec: Float
        public let rampDownPerSec: Float
        /// Extra fan level per °C/s of rising temperature (capped by the controller).
        public let riseBoost: Float
        /// When true the profile never controls fans (Apple Auto).
        public let handsOff: Bool

        public init(points: [Point], engageTemp: Float, releaseTemp: Float,
                    engageDelay: Float = 10, releaseDelay: Float = 30,
                    targetTemp: Float, rampUpPerSec: Float = 0.08, rampDownPerSec: Float = 0.03,
                    riseBoost: Float = 0, handsOff: Bool = false) {
            self.points = points.sorted { $0.temp < $1.temp }
            self.engageTemp = engageTemp
            self.releaseTemp = releaseTemp
            self.engageDelay = engageDelay
            self.releaseDelay = releaseDelay
            self.targetTemp = targetTemp
            self.rampUpPerSec = rampUpPerSec
            self.rampDownPerSec = rampDownPerSec
            self.riseBoost = riseBoost
            self.handsOff = handsOff
        }

        /// Steady-state fan level for a smoothed core temperature. Shared by the
        /// controller and the menu bar preview so they can never disagree.
        public func level(at temp: Float) -> Float {
            guard !handsOff, let first = points.first, let last = points.last else { return 0 }
            if temp <= first.temp { return clamp(first.level) }
            if temp >= last.temp { return clamp(last.level) }
            for (low, high) in zip(points, points.dropFirst()) where temp <= high.temp {
                let span = high.temp - low.temp
                guard span > 0 else { return clamp(high.level) }
                let t = (temp - low.temp) / span
                return clamp(low.level + t * (high.level - low.level))
            }
            return clamp(last.level)
        }

        /// Temperature where the curve first reaches full speed.
        public var fullSpeedTemp: Float {
            points.first { $0.level >= 1 }?.temp ?? points.last?.temp ?? engageTemp
        }

        private func clamp(_ value: Float) -> Float { min(max(value, 0), 1) }
    }

    public init(id: String, name: String, summary: String = "", curve: Curve) {
        self.id = id
        self.name = name
        self.summary = summary
        self.curve = curve
    }
}

// MARK: - Built-in Profiles
//
// Tuned on an M4 MacBook Pro (one fan, 2317–6550 RPM). Measured Apple Auto
// behaviour under a sustained full load: it let the core diodes reach 105–109°C
// and the TCMz hotspot about 115°C, raising the fan slowly from ~2,800 to
// ~5,000 RPM over 90 seconds. It keeps the fan off for light work.
//
// The profiles stay out of light work like Apple does, then follow the core
// temperature directly and much earlier. Default runs 30–40% of the fan range
// around 80°C, and its sustained-load trim settles long workloads near 84°C
// core instead of letting them climb past 100°C.

extension FanProfile {
    /// Proactive default: takes over in moderate heat, holds sustained work
    /// near 84°C core, and reaches full speed by 97°C.
    public static let `default` = FanProfile(
        id: "default",
        name: "Default",
        summary: "Cooler than Apple Auto under sustained load",
        curve: Curve(points: [.init(70, 0), .init(76, 0.15), .init(82, 0.40),
                              .init(88, 0.65), .init(93, 0.85), .init(97, 1)],
                     engageTemp: 70, releaseTemp: 62, engageDelay: 10, releaseDelay: 30,
                     targetTemp: 84, rampUpPerSec: 0.08, rampDownPerSec: 0.03,
                     riseBoost: 0.04)
    )

    /// Quiet: stays in Apple Auto longer and lets sustained work settle near
    /// 90°C core — still far cooler than Apple Auto under full load.
    public static let quiet = FanProfile(
        id: "silent",
        name: "Quiet",
        summary: "Takes over only under sustained heat",
        curve: Curve(points: [.init(78, 0), .init(84, 0.25), .init(90, 0.50),
                              .init(95, 0.75), .init(99, 1)],
                     engageTemp: 78, releaseTemp: 68, engageDelay: 15, releaseDelay: 45,
                     targetTemp: 90, rampUpPerSec: 0.05, rampDownPerSec: 0.02,
                     riseBoost: 0)
    )

    /// Performance: starts early and keeps sustained work near 78°C core.
    public static let performance = FanProfile(
        id: "aggressive",
        name: "Performance",
        summary: "Keeps sustained work coolest; loudest",
        curve: Curve(points: [.init(62, 0), .init(68, 0.15), .init(75, 0.45),
                              .init(82, 0.75), .init(88, 1)],
                     engageTemp: 62, releaseTemp: 55, engageDelay: 5, releaseDelay: 30,
                     targetTemp: 78, rampUpPerSec: 0.12, rampDownPerSec: 0.04,
                     riseBoost: 0.06)
    )

    /// Central registry for profiles shown in the app and accepted by the CLI.
    /// Add a profile here; no profile-specific controller branch is needed.
    public static let available: [FanProfile] = [quiet, `default`, performance]
    public static let builtIn: [FanProfile] = available

    /// A return-to-system mode, kept separate from the profile registry.
    public static let system = FanProfile(
        id: "system", name: "Apple Auto", summary: "macOS controls the fans",
        curve: Curve(points: [], engageTemp: 999, releaseTemp: 999,
                     targetTemp: 999, handsOff: true)
    )

    /// Resolve saved or legacy ids to the current profile. Unknown ids map to
    /// Default so old preferences remain usable.
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

    /// Built-in profiles plus any decodable profile JSON saved by the user.
    /// Files in an older schema are skipped.
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
    /// Default silicon hotspot limit. Sustained readings at or above it force
    /// full fan speed until the hotspot cools by `safetyClearMargin`.
    public static let safetyTempThreshold: Float = 105.0
    /// The user-adjustable range for the safety limit.
    public static let safetyLimitRange: ClosedRange<Float> = 90...115
    /// Hysteresis used by the daemon's thermal floor.
    public static let hysteresisDegrees: Float = 5.0
    /// The app's safety override clears once the hotspot is this far below the limit.
    public static let safetyClearMargin: Float = 8.0

    /// Conservative battery cooling demand: begin increasing fan level at 38°C
    /// and request full speed by 40°C. Apple publishes ambient operating ranges
    /// but no universal pack-degradation cutoff, so this is a policy, not a
    /// hardware damage threshold.
    public static func batteryCoolingTarget(for temperature: Float) -> Float {
        min(max((temperature - 38) / 2, 0), 1)
    }
}
