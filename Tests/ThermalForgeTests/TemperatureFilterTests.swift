import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Temperature filter")
struct TemperatureFilterTests {
    @Test("Adopts initial sample immediately with no cold-start lag")
    func initialSampleAdoption() {
        var filter = TemperatureFilter(isEnabled: true, rampUpWindowSeconds: 10.0, rampDownWindowSeconds: 30.0)
        let first = filter.update(rawTemp: 55.0, nowUptime: 1_000_000_000)
        #expect(first == 55.0)
        #expect(filter.filteredValue == 55.0)
    }

    @Test("Passthrough when filter is disabled")
    func disabledPassthrough() {
        var filter = TemperatureFilter(isEnabled: false, rampUpWindowSeconds: 10.0, rampDownWindowSeconds: 30.0)
        _ = filter.update(rawTemp: 50.0, nowUptime: 1_000_000_000)
        let second = filter.update(rawTemp: 70.0, nowUptime: 2_000_000_000)
        #expect(second == 70.0)
    }

    @Test("Symmetric response: rise and fall have identical magnitude with the same time constant")
    func symmetricRiseAndFall() {
        var riseFilter = TemperatureFilter(isEnabled: true, rampUpWindowSeconds: 10.0, rampDownWindowSeconds: 30.0)
        _ = riseFilter.update(rawTemp: 50.0, nowUptime: 1_000_000_000)
        // 1 second step up by +20°C (to 70°C) with tau = 10s
        let risen = riseFilter.update(rawTemp: 70.0, timeConstant: 10.0, nowUptime: 2_000_000_000)
        let riseDelta = risen - 50.0

        var fallFilter = TemperatureFilter(isEnabled: true, rampUpWindowSeconds: 10.0, rampDownWindowSeconds: 30.0)
        _ = fallFilter.update(rawTemp: 70.0, nowUptime: 1_000_000_000)
        // 1 second step down by -20°C (to 50°C) with tau = 10s
        let fallen = fallFilter.update(rawTemp: 50.0, timeConstant: 10.0, nowUptime: 2_000_000_000)
        let fallDelta = 70.0 - fallen

        // Rising delta and falling delta must be equal (symmetric, no ratchet effect)
        #expect(abs(riseDelta - fallDelta) < 0.001)
    }

    @Test("State-dependent time constants: ramp-up (10s) responds faster than ramp-down (30s)")
    func rampUpFasterThanRampDown() {
        var upFilter = TemperatureFilter(isEnabled: true, rampUpWindowSeconds: 10.0, rampDownWindowSeconds: 30.0)
        _ = upFilter.update(rawTemp: 50.0, nowUptime: 1_000_000_000)
        let upResult = upFilter.update(rawTemp: 70.0, timeConstant: 10.0, nowUptime: 2_000_000_000)
        let upChange = upResult - 50.0

        var downFilter = TemperatureFilter(isEnabled: true, rampUpWindowSeconds: 10.0, rampDownWindowSeconds: 30.0)
        _ = downFilter.update(rawTemp: 50.0, nowUptime: 1_000_000_000)
        let downResult = downFilter.update(rawTemp: 70.0, timeConstant: 30.0, nowUptime: 2_000_000_000)
        let downChange = downResult - 50.0

        // 10s time constant reacts more in 1 second than 30s time constant
        #expect(upChange > downChange)
        #expect(upChange > 1.8) // ~1.9°C in 1s for tau=10s
        #expect(downChange < 0.8) // ~0.65°C in 1s for tau=30s
    }

    @Test("Reset clears filtered state")
    func resetClearsState() {
        var filter = TemperatureFilter(isEnabled: true, rampUpWindowSeconds: 10.0, rampDownWindowSeconds: 30.0)
        _ = filter.update(rawTemp: 60.0, nowUptime: 1_000_000_000)
        #expect(filter.filteredValue != nil)

        filter.reset()
        #expect(filter.filteredValue == nil)

        // After reset, next value is adopted immediately
        let adopted = filter.update(rawTemp: 45.0, nowUptime: 2_000_000_000)
        #expect(adopted == 45.0)
    }
}
