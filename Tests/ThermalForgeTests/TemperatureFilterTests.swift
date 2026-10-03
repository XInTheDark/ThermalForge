import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Temperature filter")
struct TemperatureFilterTests {
    @Test("Adopts the first sample immediately")
    func firstSample() {
        var filter = TemperatureFilter()
        #expect(filter.update(rawTemp: 65, dt: 1) == 65)
        #expect(filter.filteredValue == 65)
    }

    @Test("Passes samples through when disabled")
    func disabled() {
        var filter = TemperatureFilter(isEnabled: false)
        filter.update(rawTemp: 60, dt: 1)
        #expect(filter.update(rawTemp: 90, dt: 1) == 90)
    }

    @Test("Rises faster than it falls")
    func asymmetric() {
        var rising = TemperatureFilter(attackSeconds: 4, decaySeconds: 20)
        rising.update(rawTemp: 60, dt: 1)
        let up = rising.update(rawTemp: 80, dt: 4) - 60

        var falling = TemperatureFilter(attackSeconds: 4, decaySeconds: 20)
        falling.update(rawTemp: 80, dt: 1)
        let down = 80 - falling.update(rawTemp: 60, dt: 4)

        // One time constant covers ~63% of a step.
        #expect(abs(up - 20 * 0.632) < 0.1)
        #expect(down < up / 3)
    }

    @Test("A one-second spike moves the filtered value only partway")
    func spikeRejection() {
        var filter = TemperatureFilter()
        filter.update(rawTemp: 60, dt: 1)
        let spiked = filter.update(rawTemp: 95, dt: 1)
        #expect(spiked < 70)
        // And it doesn't drop straight back afterwards.
        let after = filter.update(rawTemp: 60, dt: 1)
        #expect(after > 63)
    }

    @Test("Reset clears history")
    func reset() {
        var filter = TemperatureFilter()
        filter.update(rawTemp: 60, dt: 1)
        filter.reset()
        #expect(filter.filteredValue == nil)
        #expect(filter.update(rawTemp: 80, dt: 1) == 80)
    }
}
