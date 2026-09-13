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

    @Test("Stats-aligned core diodes drive nominal peak while hotspots drive safety")
    func coreDiodesVsHotspot() {
        // Typical M4 sensor reading matching the Stats app
        let m4Status = ThermalStatus(
            fans: [],
            temperatures: [
                // E-cores (~61-62°C)
                "Te05": 62.1, "Te0S": 61.1, "Te09": 62.4, "Te0H": 61.6,
                // P-cores (~63-64°C, peak 64.0°C on Tp0V)
                "Tp01": 63.8, "Tp05": 63.9, "Tp09": 63.8, "Tp0D": 63.3,
                "Tp0V": 64.0, "Tp0Y": 63.9, "Tp0b": 63.4, "Tp0e": 63.2,
                // Hotspots (78-82°C)
                "Tp0W": 78.0, "TCMz": 82.0,
                // GPU cores (peak 60.6°C on Tg0H)
                "Tg0G": 55.3, "Tg0H": 60.6,
            ]
        )

        // Core diode peak must match Stats (64.0°C)
        #expect(m4Status.cpuCoreMaxTemp == 64.0)
        #expect(m4Status.gpuCoreMaxTemp == 60.6)
        #expect(m4Status.nominalPeakTemp == 64.0)

        // Hotspot and safety floor must see the 82.0°C peak
        #expect(m4Status.siliconHotspotTemp == 82.0)
        #expect(m4Status.safetyPeakTemp == 82.0)
        #expect(m4Status.hasUsableSafetyTemperature == true)
    }

    @Test("M3 generation sensor recognition (Te and Tf prefixes)")
    func m3Sensors() {
        let m3Status = ThermalStatus(
            fans: [],
            temperatures: [
                "Te05": 58.0, // E-core
                "Tf04": 66.5, // P-core
                "Tf14": 52.0, // GPU
            ]
        )
        #expect(m3Status.cpuCoreMaxTemp == 66.5)
        #expect(m3Status.gpuCoreMaxTemp == 52.0)
        #expect(m3Status.nominalPeakTemp == 66.5)
        #expect(m3Status.hasUsableSafetyTemperature == true)
    }

    @Test("M4 hotspot Tp0f is excluded from core max and isolated to hotspot/safety")
    func m4HotspotTp0f() {
        let m4Status = ThermalStatus(
            fans: [],
            temperatures: [
                // E-cores
                "Te05": 60.7, "Te09": 60.9, "Te0H": 59.8, "Te0S": 59.6,
                // P-cores (peak 66.3°C on Tp0V)
                "Tp01": 64.7, "Tp05": 65.4, "Tp09": 65.4, "Tp0D": 65.2,
                "Tp0V": 66.3, "Tp0Y": 65.5, "Tp0b": 65.5, "Tp0e": 65.4,
                // Hotspots (Tp0f is 82.5°C on M4)
                "Tp0f": 82.5, "Tp0W": 81.6, "TCMz": 82.7,
            ]
        )
        // CPU core max must be 66.3°C (Tp0V), NOT 82.5°C (Tp0f)
        #expect(m4Status.cpuCoreMaxTemp == 66.3)
        #expect(m4Status.nominalPeakTemp == 66.3)
        #expect(m4Status.siliconHotspotTemp == 82.7)
        #expect(m4Status.safetyPeakTemp == 82.7)
    }

    @Test("ThermalStatus encodes summary fields into JSON for status reporting")
    func thermalStatusEncoding() throws {
        let status = ThermalStatus(
            fans: [],
            temperatures: [
                "Te05": 60.0,
                "Tp01": 65.0,
                "Tp0f": 82.0,
            ]
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(status)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"cpu_core_max\" : 65") || json.contains("\"cpu_core_max\":65"))
        #expect(json.contains("\"silicon_hotspot\" : 82") || json.contains("\"silicon_hotspot\":82"))
        #expect(json.contains("\"nominal_peak\" : 65") || json.contains("\"nominal_peak\":65"))
    }
}
