//
//  TemperatureFilter.swift
//  ThermalForgeCore
//
//  Asymmetric exponential moving average for the control temperature.
//

import Darwin
import Foundation

/// Exponential moving average with a shorter time constant for rising
/// temperatures (attack) than for falling ones (decay).
///
/// Core diodes on Apple Silicon jump by 10–20°C within a second when a burst
/// starts and fall just as fast when it stops, while the heatsink and chassis
/// change over tens of seconds. A quick attack lets the fans respond to real
/// load within a few seconds; a slow decay keeps them from chasing every pause
/// between bursts, which is what causes audible hunting and repeated hot cycles.
public struct TemperatureFilter: Sendable, Equatable {
    public var isEnabled: Bool
    /// Time constant while the input is above the filtered value, seconds.
    public var attackSeconds: Double
    /// Time constant while the input is below the filtered value, seconds.
    public var decaySeconds: Double

    public private(set) var filteredValue: Float?

    public static let defaultAttackSeconds: Double = 4
    public static let defaultDecaySeconds: Double = 20

    public init(isEnabled: Bool = true,
                attackSeconds: Double = TemperatureFilter.defaultAttackSeconds,
                decaySeconds: Double = TemperatureFilter.defaultDecaySeconds) {
        self.isEnabled = isEnabled
        self.attackSeconds = max(0.5, attackSeconds)
        self.decaySeconds = max(0.5, decaySeconds)
    }

    /// Advance the filter by `dt` seconds toward `rawTemp`.
    @discardableResult
    public mutating func update(rawTemp: Float, dt: Double) -> Float {
        guard isEnabled, let current = filteredValue, dt > 0 else {
            filteredValue = rawTemp
            return rawTemp
        }
        let tau = rawTemp >= current ? attackSeconds : decaySeconds
        let alpha = Float(1.0 - exp(-dt / max(0.5, tau)))
        let next = current + alpha * (rawTemp - current)
        filteredValue = next
        return next
    }

    /// Forget history (profile change, wake from sleep, sensor recovery).
    public mutating func reset() {
        filteredValue = nil
    }
}
