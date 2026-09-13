import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Profiles")
struct ProfileTests {
    @Test("Built-in profiles are registered and obsolete legacy ids migrate")
    func registryAndMigration() {
        #expect(FanProfile.available.count == 3)
        #expect(FanProfile.available.map(\.id) == ["default", "silent", "aggressive"])
        #expect(FanProfile.selectable(id: nil).id == "default")
        #expect(FanProfile.selectable(id: "default").id == "default")
        #expect(FanProfile.selectable(id: "silent").id == "silent")
        #expect(FanProfile.selectable(id: "aggressive").id == "aggressive")
        #expect(FanProfile.selectable(id: "system").id == "system")
        for id in ["smart", "balanced", "performance", "max", "removed", "unknown"] {
            #expect(FanProfile.selectable(id: id).id == "default")
        }
    }

    @Test("Default curve is proactive and data-driven")
    func defaultCurve() {
        let profile = FanProfile.default
        #expect(profile.name == "Default")
        #expect(profile.curve.stopTemp == 55)
        #expect(profile.curve.startTemp == 60)
        #expect(profile.curve.ceilingTemp == 92)
        #expect(profile.curve.maxRPMPercent == 1)
        #expect(profile.curve.curveShape == .sCurve)
        #expect(profile.curve.sustainedTriggerSec == 5)
        #expect(profile.curve.rateOfChangeBoost == 0.15)
    }

    @Test("Silent profile prioritizes acoustic comfort and smooth transitions")
    func silentCurve() {
        let profile = FanProfile.silent
        #expect(profile.name == "Silent")
        #expect(profile.curve.stopTemp == 65)
        #expect(profile.curve.startTemp == 70)
        #expect(profile.curve.ceilingTemp == 96)
        #expect(profile.curve.maxRPMPercent == 1)
        #expect(profile.curve.curveShape == .easeIn)
        #expect(profile.curve.sustainedTriggerSec == 10)
        #expect(profile.curve.rampUpPerSec == 0.04)
        #expect(profile.curve.rampDownPerSec == 0.02)
        #expect(profile.curve.rateOfChangeBoost == 0)

        let curve = profile.curve
        // Fans stay off below 70°C
        #expect(curve.displayPercent(at: 65) == 0)
        #expect(curve.displayPercent(at: 70) == 0)
        #expect(curve.targetPercent(at: 65, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 68, fansCurrentlyRunning: true) == 0.001)

        // Suppressed low-mid range via easeIn (pos^2)
        // At 75°C: pos = (75 - 70) / (96 - 70) = 5 / 26 ≈ 0.1923; pos^2 ≈ 0.037
        #expect(curve.displayPercent(at: 75) < 0.05)
        // At 83°C: pos = 13 / 26 = 0.5; pos^2 = 0.25
        #expect(abs(curve.displayPercent(at: 83) - 0.25) < 0.01)

        // Full cooling at ceiling
        #expect(curve.displayPercent(at: 96) == 1.0)
        #expect(curve.targetPercent(at: 96, fansCurrentlyRunning: true) == 1.0)
    }

    @Test("Aggressive profile reaches ceiling early for sustained performance")
    func aggressiveCurve() {
        let profile = FanProfile.aggressive
        #expect(profile.name == "Aggressive")
        #expect(profile.curve.stopTemp == 53)
        #expect(profile.curve.startTemp == 58)
        #expect(profile.curve.ceilingTemp == 86)
        #expect(profile.curve.maxRPMPercent == 1)
        #expect(profile.curve.curveShape == .sCurve)
        #expect(profile.curve.sustainedTriggerSec == 2.5)
        #expect(profile.curve.rampUpPerSec == 0.18)
        #expect(profile.curve.rampDownPerSec == 0.04)
        #expect(profile.curve.rateOfChangeBoost == 0.22)

        let curve = profile.curve
        // Off below 55°C (does not blast fans at 55°C)
        #expect(curve.targetPercent(at: 53, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 55, fansCurrentlyRunning: false) == nil)
        #expect(curve.displayPercent(at: 55) == 0)

        // Engages at 58°C
        #expect(curve.displayPercent(at: 58) == 0)

        // Mid-point at 72°C: pos = 14 / 28 = 0.5; s-curve(0.5) = 0.50
        #expect(abs(curve.displayPercent(at: 72) - 0.50) < 0.01)

        // High cooling early: at 79°C pos = 21 / 28 = 0.75, s-curve(0.75) ≈ 0.844
        #expect(curve.displayPercent(at: 79) > 0.80)

        // Full speed at 86°C
        #expect(curve.displayPercent(at: 86) == 1.0)
        #expect(curve.targetPercent(at: 86, fansCurrentlyRunning: true) == 1.0)
    }

    @Test("Curve math handles hysteresis and display preview")
    func curveMath() {
        let curve = FanProfile.default.curve
        #expect(curve.targetPercent(at: 45, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 54, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 57, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 57, fansCurrentlyRunning: true) == 0.001)
        #expect(curve.targetPercent(at: 92, fansCurrentlyRunning: true) == 1)
        #expect(curve.displayPercent(at: 55) == 0)
        #expect(curve.displayPercent(at: 60) == 0)
        #expect(curve.displayPercent(at: 92) == 1)
        #expect(abs(curve.displayPercent(at: 76) - 0.50) < 0.01)
        #expect(curve.displayPercent(at: 82) > 0.65)
        #expect(curve.displayPercent(at: 82) < 0.85)
    }

    @Test("Custom low-temperature threshold adjusts curve and hysteresis")
    func lowTemperatureRegime() {
        let base = FanProfile.default
        let customized = base.withLowTempThreshold(65)
        #expect(customized.curve.startTemp == 65)
        #expect(customized.curve.stopTemp == 60)
        #expect(customized.curve.ceilingTemp == 92)

        // Below start threshold: stays off (hands off to Apple Auto)
        #expect(customized.curve.targetPercent(at: 62, fansCurrentlyRunning: false) == nil)

        // In hysteresis band: keeps running if already running
        #expect(customized.curve.targetPercent(at: 62, fansCurrentlyRunning: true) == 0.001)

        // At or below stop threshold: turns off
        #expect(customized.curve.targetPercent(at: 60, fansCurrentlyRunning: true) == nil)
        #expect(customized.curve.targetPercent(at: 58, fansCurrentlyRunning: true) == nil)

        // Above start threshold: active curve
        #expect(customized.curve.targetPercent(at: 66, fansCurrentlyRunning: false) != nil)
        #expect(customized.curve.targetPercent(at: 92, fansCurrentlyRunning: true) == 1.0)

        // Apple Auto (handsOff) profile is unaffected
        let systemCustomized = FanProfile.system.withLowTempThreshold(65)
        #expect(systemCustomized.curve.handsOff == true)
        #expect(systemCustomized.curve.targetPercent(at: 70, fansCurrentlyRunning: false) == nil)

        // When low-temperature hybrid mode is disabled, app always takes control at minimum RPM or higher
        let alwaysActive = base.withLowTempThreshold(enabled: false, threshold: 60)
        #expect(alwaysActive.curve.stopTemp == 0)
        #expect(alwaysActive.curve.startTemp == 60)
        #expect(alwaysActive.curve.targetPercent(at: 40, fansCurrentlyRunning: false) == 0.001)
        #expect(alwaysActive.curve.targetPercent(at: 40, fansCurrentlyRunning: true) == 0.001)
        #expect((alwaysActive.curve.targetPercent(at: 76, fansCurrentlyRunning: true) ?? 0) > 0.4)
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
