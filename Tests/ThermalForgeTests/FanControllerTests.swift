import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Fan controller")
struct FanControllerTests {
    /// Run the controller at 100 ms steps for `seconds` with a constant input.
    @discardableResult
    private func run(_ controller: inout FanController, _ input: ControlInput, seconds: Double) -> ControlOutput {
        var output: ControlOutput!
        for _ in 0..<max(Int((seconds * 10).rounded()), 1) {
            output = controller.step(input, dt: 0.1)
        }
        return output
    }

    private func input(_ core: Float, hotspot: Float? = nil, battery: Float? = nil,
                       pressure: ThermalPressure = .nominal, external: Bool = false,
                       current: Float? = 0) -> ControlInput {
        ControlInput(coreTemp: core, hotspotTemp: hotspot ?? core + 8, batteryTemp: battery,
                     pressure: pressure, externalPower: external, currentLevel: current)
    }

    private var noSmoothing: ControlSettings {
        ControlSettings(filter: TemperatureFilter(isEnabled: false))
    }

    @Test("Stays in Apple Auto while cool and through short bursts")
    func ignoresShortBursts() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        #expect(run(&controller, input(55), seconds: 30).engaged == false)
        // A 5 s burst is shorter than Default's 10 s engage delay.
        #expect(run(&controller, input(85), seconds: 5).engaged == false)
        #expect(run(&controller, input(55), seconds: 5).engaged == false)
    }

    @Test("Smoothing keeps a one-second spike from reaching the takeover temperature")
    func smoothedSpike() {
        var controller = FanController(profile: .default)
        run(&controller, input(55), seconds: 10)
        let output = run(&controller, input(95), seconds: 1)
        #expect(output.filteredTemp < 70)
        #expect(run(&controller, input(55), seconds: 20).engaged == false)
    }

    @Test("Engages after the delay, ramps within limits, and follows the curve")
    func engagesAndRamps() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        // 83°C is below Default's 84°C sustained target, so only the curve acts.
        var output = run(&controller, input(83), seconds: 10.1)
        #expect(output.engaged)
        // Ramp-up is limited to 0.08/s.
        output = run(&controller, input(83), seconds: 2)
        #expect(output.level <= 0.17)
        output = run(&controller, input(83), seconds: 10)
        #expect(abs(output.level - FanProfile.default.curve.level(at: 83)) < 0.01)
        #expect(output.driver == .curve)
    }

    @Test("Takes over at Apple Auto's current speed instead of dropping the fans")
    func bumplessTakeover() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        let output = run(&controller, input(72, current: 0.6), seconds: 10.1)
        #expect(output.engaged)
        #expect(output.level > 0.55)
        // Then it eases down toward the curve at the ramp-down rate.
        let later = run(&controller, input(72, current: 0.6), seconds: 5)
        #expect(later.level < output.level && later.level > output.level - 0.2)
    }

    @Test("Hands back to Apple Auto only after cooling, waiting, and reaching minimum")
    func releaseHysteresis() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        run(&controller, input(90), seconds: 30)
        // Between release (62) and engage (70): stays engaged at minimum.
        var output = run(&controller, input(66), seconds: 60)
        #expect(output.engaged)
        #expect(output.level == 0)
        // Below release, it must wait the release delay.
        output = run(&controller, input(58), seconds: 20)
        #expect(output.engaged)
        output = run(&controller, input(58), seconds: 11)
        #expect(output.engaged == false)
    }

    @Test("Sustained load above target adds a slow trim that decays afterwards")
    func sustainedTrim() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        let early = run(&controller, input(87), seconds: 20)
        let late = run(&controller, input(87), seconds: 120)
        #expect(late.sustainedTrim > early.sustainedTrim)
        #expect(late.level > FanProfile.default.curve.level(at: 87) + 0.1)
        #expect(late.driver == .sustained)
        let cooled = run(&controller, input(75), seconds: 60)
        #expect(cooled.sustainedTrim == 0)
    }

    @Test("Rising temperature adds an early boost")
    func risingBoost() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        run(&controller, input(78), seconds: 15)
        var temp: Float = 78
        var output: ControlOutput!
        for _ in 0..<30 {
            temp += 0.2   // 2°C/s
            output = controller.step(input(temp), dt: 0.1)
        }
        #expect(output.demand > FanProfile.default.curve.level(at: temp) + 0.02)
    }

    @Test("Safety override needs a sustained hotspot, maxes instantly, and clears itself")
    func safetyOverride() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        run(&controller, input(60), seconds: 5)
        // A one-second hotspot spike is ignored.
        #expect(run(&controller, input(60, hotspot: 110), seconds: 1).safetyOverride == false)
        #expect(run(&controller, input(60, hotspot: 90), seconds: 1).safetyOverride == false)
        // Two seconds at the limit engages it, even from Apple Auto, at full speed.
        let hot = run(&controller, input(60, hotspot: 106), seconds: 2.1)
        #expect(hot.engaged && hot.safetyOverride && hot.level == 1 && hot.driver == .safety)
        // Just below the limit is not enough to clear.
        #expect(run(&controller, input(60, hotspot: 100), seconds: 20).safetyOverride)
        // 8°C below the limit for 10 s clears it; fans then ramp down, not drop.
        let cleared = run(&controller, input(60, hotspot: 95), seconds: 10.1)
        #expect(cleared.safetyOverride == false)
        #expect(cleared.level > 0.9)
    }

    @Test("macOS thermal pressure sets a floor and forces takeover")
    func pressureFloor() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        let serious = run(&controller, input(60, pressure: .serious), seconds: 15)
        #expect(serious.engaged)
        #expect(serious.level >= 0.8)
        #expect(serious.driver == .pressure)
        let critical = run(&controller, input(60, pressure: .critical), seconds: 0.1)
        #expect(critical.level == 1)
    }

    @Test("A warm battery raises the fans from 38°C to full at 40°C")
    func batteryFloor() {
        var controller = FanController(profile: .default, settings: noSmoothing)
        let output = run(&controller, input(55, battery: 39), seconds: 20)
        #expect(output.engaged)
        #expect(abs(output.level - 0.5) < 0.01)
        #expect(output.driver == .battery)
    }

    @Test("The adapter transform applies above minimum only")
    func adapterTransform() {
        var battery = FanController(profile: .default, settings: noSmoothing)
        var adapter = FanController(profile: .default, settings: noSmoothing)
        let onBattery = run(&battery, input(85), seconds: 30)
        let onAdapter = run(&adapter, input(85, external: true), seconds: 30)
        #expect(abs(onAdapter.level - (onBattery.level * 1.1 + 0.05)) < 0.02)

        var cool = FanController(profile: .default, settings: noSmoothing)
        run(&cool, input(85, external: true), seconds: 20)
        #expect(run(&cool, input(66, external: true), seconds: 60).level == 0)
    }

    @Test("Keep-control mode never hands back to Apple Auto")
    func alwaysControl() {
        var settings = noSmoothing
        settings.handBackWhenCool = false
        var controller = FanController(profile: .default, settings: settings)
        let output = run(&controller, input(45), seconds: 120)
        #expect(output.engaged)
        #expect(output.level == 0)
        #expect(output.driver == .standby)
    }

    @Test("A custom takeover temperature moves both thresholds")
    func customTakeover() {
        let settings = ControlSettings(takeoverTemp: 80)
        let thresholds = settings.thresholds(for: FanProfile.default.curve)
        #expect(thresholds.engage == 80)
        #expect(thresholds.release == 72)

        var controller = FanController(profile: .default, settings: ControlSettings(takeoverTemp: 80, filter: TemperatureFilter(isEnabled: false)))
        #expect(run(&controller, input(75), seconds: 30).engaged == false)
        #expect(run(&controller, input(81), seconds: 10.1).engaged)
    }

    @Test("Apple Auto profile never controls the fans")
    func handsOff() {
        var controller = FanController(profile: .system, settings: noSmoothing)
        let output = run(&controller, input(99, hotspot: 112, pressure: .critical), seconds: 10)
        #expect(output.engaged == false)
        #expect(output.driver == .appleAuto)
    }
}
