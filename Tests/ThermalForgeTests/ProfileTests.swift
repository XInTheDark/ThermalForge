import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Profiles")
struct ProfileTests {
    @Test("Default is the only selectable built-in and legacy ids migrate")
    func registryAndMigration() {
        #expect(FanProfile.available.count == 1)
        #expect(FanProfile.available.first?.id == "default")
        for id in [nil, "default", "smart", "silent", "balanced", "performance", "max", "removed"] {
            #expect(FanProfile.selectable(id: id).id == "default")
        }
    }

    @Test("Default curve is proactive and data-driven")
    func defaultCurve() {
        let profile = FanProfile.default
        #expect(profile.name == "Default")
        #expect(profile.curve.stopTemp == 50)
        #expect(profile.curve.startTemp == 55)
        #expect(profile.curve.ceilingTemp == 92)
        #expect(profile.curve.maxRPMPercent == 1)
        #expect(profile.curve.curveShape == .sCurve)
        #expect(profile.curve.sustainedTriggerSec == 2)
        #expect(profile.curve.rateOfChangeBoost == 0.15)
    }

    @Test("Curve math handles hysteresis and display preview")
    func curveMath() {
        let curve = FanProfile.default.curve
        #expect(curve.targetPercent(at: 45, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 52, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 52, fansCurrentlyRunning: true) == 0.001)
        #expect(curve.targetPercent(at: 92, fansCurrentlyRunning: true) == 1)
        #expect(curve.displayPercent(at: 50) == 0)
        #expect(curve.displayPercent(at: 92) == 1)
        #expect(curve.displayPercent(at: 73.5) > 0.45)
        #expect(curve.displayPercent(at: 73.5) < 0.55)
        #expect(curve.displayPercent(at: 80) > 0.70)
        #expect(curve.displayPercent(at: 80) < 0.80)
    }

    @Test("Curve JSON remains backward compatible")
    func jsonRoundTrip() throws {
        let profile = FanProfile.default
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(FanProfile.self, from: data) == profile)

        let legacy = """
        {"stopTemp":50,"startTemp":55,"ceilingTemp":70,"maxRPMPercent":0.6,"handsOff":false,"alwaysOn":false,"curveShape":"linear","rampUpPerSec":0.05,"rampDownPerSec":0.025,"sustainedTriggerSec":8,"instantEngage":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FanProfile.Curve.self, from: legacy)
        #expect(decoded.rateOfChangeBoost == 0)
    }

    @Test("Safety constants remain conservative")
    func safety() {
        #expect(FanProfile.safetyTempThreshold == 105)
        #expect(FanProfile.hysteresisDegrees == 5)
        #expect(FanProfile.batteryCoolingTarget(for: 37) == 0)
        #expect(FanProfile.batteryCoolingTarget(for: 38) == 0)
        #expect(FanProfile.batteryCoolingTarget(for: 39) == 0.5)
        #expect(FanProfile.batteryCoolingTarget(for: 40) == 1)
    }

    @Test("Power-source transform applies multiplier and shift")
    func powerTransform() {
        let transform = FanPercentTransform(shift: 0.05, multiplier: 1.10)
        #expect(abs(transform.apply(to: 0.5) - 0.60) < 0.001)
        #expect(transform.apply(to: 0.99) == 1)
        #expect(FanPercentTransform.identity.apply(to: 0.42) == 0.42)
    }

    @Test("An empty thermal snapshot is not treated as a safe low temperature")
    func missingSafetySensor() {
        let empty = ThermalStatus(fans: [], temperatures: [:])
        let cpu = ThermalStatus(fans: [], temperatures: ["TC0P": 55])
        #expect(empty.hasUsableSafetyTemperature == false)
        #expect(cpu.hasUsableSafetyTemperature == true)
        #expect(empty.safetyPeakTemp == 0)
    }
}
