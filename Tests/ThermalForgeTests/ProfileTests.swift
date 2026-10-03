import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Profiles")
struct ProfileTests {
    @Test("Built-in profiles are registered and legacy ids migrate")
    func registryAndMigration() {
        #expect(FanProfile.available.map(\.id) == ["silent", "default", "aggressive"])
        #expect(FanProfile.available.map(\.name) == ["Quiet", "Default", "Performance"])
        #expect(FanProfile.selectable(id: nil).id == "default")
        #expect(FanProfile.selectable(id: "system").id == "system")
        for id in ["smart", "balanced", "performance", "max", "unknown"] {
            #expect(FanProfile.selectable(id: id).id == "default")
        }
    }

    @Test("Every curve is well formed")
    func curvesWellFormed() {
        for profile in FanProfile.available {
            let curve = profile.curve
            #expect(!curve.handsOff)
            #expect(curve.releaseTemp < curve.engageTemp, "\(profile.name) needs hysteresis")
            #expect(curve.points.first?.level == 0, "\(profile.name) starts at minimum RPM")
            #expect(curve.points.last?.level == 1, "\(profile.name) reaches full speed")
            #expect(curve.points.first?.temp == curve.engageTemp)
            for (a, b) in zip(curve.points, curve.points.dropFirst()) {
                #expect(a.temp < b.temp)
                #expect(a.level <= b.level)
            }
            #expect(curve.targetTemp > curve.engageTemp && curve.targetTemp < curve.fullSpeedTemp)
            #expect(curve.rampUpPerSec > curve.rampDownPerSec, "\(profile.name) should settle slower than it reacts")
        }
    }

    @Test("Curve interpolates linearly and is flat outside its points")
    func interpolation() {
        let curve = FanProfile.default.curve
        #expect(curve.level(at: 40) == 0)
        #expect(curve.level(at: 70) == 0)
        #expect(abs(curve.level(at: 79) - 0.275) < 0.001)
        #expect(curve.level(at: 97) == 1)
        #expect(curve.level(at: 110) == 1)
        #expect(FanProfile.system.curve.level(at: 100) == 0)
    }

    @Test("Profiles are ordered Quiet ≤ Default ≤ Performance at every temperature")
    func ordering() {
        for temp in stride(from: Float(40), through: 105, by: 0.5) {
            let quiet = FanProfile.quiet.curve.level(at: temp)
            let standard = FanProfile.default.curve.level(at: temp)
            let performance = FanProfile.performance.curve.level(at: temp)
            #expect(quiet <= standard && standard <= performance, "at \(temp)°C")
        }
        #expect(FanProfile.quiet.curve.engageTemp > FanProfile.default.curve.engageTemp)
        #expect(FanProfile.default.curve.engageTemp > FanProfile.performance.curve.engageTemp)
        #expect(FanProfile.quiet.curve.targetTemp > FanProfile.default.curve.targetTemp)
        #expect(FanProfile.default.curve.targetTemp > FanProfile.performance.curve.targetTemp)
    }

    @Test("Default stays out of light work and runs 30–40% around 80°C")
    func defaultShape() {
        let curve = FanProfile.default.curve
        // Light work stays with Apple Auto (fan off).
        #expect(curve.engageTemp >= 70)
        #expect((0.30...0.40).contains(curve.level(at: 80)))
        #expect((0.45...0.60).contains(curve.level(at: 85)))
        // Full speed well before the 105–109°C cores Apple Auto allows under load.
        #expect(curve.fullSpeedTemp <= 97)
    }

    @Test("Power-source transform applies multiplier and shift")
    func powerTransform() {
        let transform = FanPercentTransform(shift: 0.05, multiplier: 1.10)
        #expect(abs(transform.apply(to: 0.5) - 0.60) < 0.001)
        #expect(transform.apply(to: 0.99) == 1)
        #expect(FanPercentTransform.identity.apply(to: 0.42) == 0.42)
        // Minimum stays minimum: the shift never applies to a zero demand.
        #expect(transform.apply(to: 0) == 0)
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
