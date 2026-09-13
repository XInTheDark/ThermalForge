//
//  TemperatureFilter.swift
//  ThermalForgeCore
//
//  Symmetric Exponential Moving Average (EMA) filter with state-dependent time constants.
//

import Darwin
import Foundation

/// Symmetric Exponential Moving Average (EMA) filter for temperature readings.
///
/// Dampens instantaneous single-core thermal diode spikes symmetrically to avoid
/// the "ratchet" or peak-detector bias of asymmetric filters.
///
/// Uses distinct physical time constants based on fan operational state:
/// - **Ramp-Up / Acceleration ($\approx 10\text{s}$)**: Responsive window during workload start and fan acceleration.
/// - **Ramp-Down / Deceleration ($\approx 30\text{s}$)**: Extended window while fans are decelerating, matching
///   chassis thermal mass dissipation and preventing audible fan speed hunting.
public struct TemperatureFilter: Sendable, Equatable {
    public var isEnabled: Bool
    public var rampUpWindowSeconds: Double
    public var rampDownWindowSeconds: Double

    public private(set) var filteredValue: Float?
    private var lastSampleUptime: UInt64?

    public init(isEnabled: Bool = true,
                rampUpWindowSeconds: Double = 10.0,
                rampDownWindowSeconds: Double = 30.0) {
        self.isEnabled = isEnabled
        self.rampUpWindowSeconds = max(1.0, rampUpWindowSeconds)
        self.rampDownWindowSeconds = max(1.0, rampDownWindowSeconds)
    }

    /// Update the filter with a new raw temperature sample using symmetric EMA.
    /// - Parameters:
    ///   - rawTemp: Raw instantaneous temperature in °C.
    ///   - timeConstant: Effective smoothing window ($\tau$) in seconds. If nil, defaults to `rampUpWindowSeconds`.
    ///   - nowUptime: Monotonic uptime timestamp in nanoseconds.
    /// - Returns: Smoothed temperature in °C.
    @discardableResult
    public mutating func update(rawTemp: Float,
                                timeConstant: Double? = nil,
                                nowUptime: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Float {
        guard isEnabled else {
            filteredValue = rawTemp
            lastSampleUptime = nowUptime
            return rawTemp
        }

        guard let current = filteredValue, let lastTime = lastSampleUptime else {
            filteredValue = rawTemp
            lastSampleUptime = nowUptime
            return rawTemp
        }

        let dt = max(0.001, Double(nowUptime - lastTime) / 1_000_000_000.0)
        lastSampleUptime = nowUptime

        // Symmetric EMA: tau is identical for rising and falling within this state.
        let tau = max(0.5, timeConstant ?? rampUpWindowSeconds)
        let alpha = Float(1.0 - exp(-dt / tau))

        let next = current + alpha * (rawTemp - current)
        filteredValue = next
        return next
    }

    /// Reset internal filter state (e.g. on profile change or sensor reinitialization).
    public mutating func reset() {
        filteredValue = nil
        lastSampleUptime = nil
    }
}
