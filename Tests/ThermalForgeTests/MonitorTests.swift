import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Thermal monitor")
struct MonitorTests {
    final class Rig: @unchecked Sendable {
        let lock = NSLock()
        var time: TimeInterval = 1000
        var core: Float = 50
        var hotspot: Float?
        var failing = false
        var fanTarget = 0
        var fanActual = 0
        var sent: [FanTarget] = []
        let actuatorQueue = DispatchQueue(label: "monitor-test-actuator")
        var monitor: ThermalMonitor!
        var actuator: FanActuator!

        init(profile: FanProfile = Rig.fastProfile, settings: ControlSettings = Rig.settings) {
            let clock: @Sendable () -> TimeInterval = { [unowned self] in self.locked { time } }
            actuator = FanActuator(queue: actuatorQueue, now: clock) { [unowned self] target in
                locked {
                    sent.append(target)
                    // A cooperative fan: it adopts whatever target it is given.
                    switch target {
                    case .system: fanTarget = 0
                    case .rpm(let rpm): fanTarget = rpm
                    case .perFan(let rpms): fanTarget = rpms[0]
                    }
                }
            }
            monitor = ThermalMonitor(source: Source(rig: self), actuator: actuator,
                                     batteryProfile: profile, adapterProfile: profile,
                                     settings: settings, sensorRefreshInterval: 1, controlLoopInterval: 0.1,
                                     pressureProvider: { .nominal }, powerProvider: { .battery },
                                     clock: clock)
        }

        /// A profile with no engage delay so tests don't need long clocks.
        static let fastProfile = FanProfile(id: "test", name: "Test", curve: .init(
            points: [.init(70, 0), .init(90, 1)], engageTemp: 70, releaseTemp: 60,
            engageDelay: 0, releaseDelay: 0, targetTemp: 85, rampUpPerSec: 1, rampDownPerSec: 1))
        static let settings = ControlSettings(filter: TemperatureFilter(isEnabled: false))

        func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

        /// Advance the clock in 100 ms ticks.
        func run(seconds: Double) {
            for _ in 0..<Int((seconds * 10).rounded()) {
                locked { time += 0.1 }
                monitor.tickNow()
                actuatorQueue.sync {}
            }
        }

        var targets: [FanTarget] { locked { sent } }
        var last: FanTarget? { targets.last }
    }

    final class Source: ThermalStatusSource, @unchecked Sendable {
        unowned let rig: Rig
        init(rig: Rig) { self.rig = rig }
        func status() throws -> ThermalStatus {
            let (failing, core, hotspot, target, actual) = rig.locked {
                (rig.failing, rig.core, rig.hotspot, rig.fanTarget, rig.fanActual)
            }
            if failing { throw ThermalForgeError.readFailed("test") }
            return ThermalStatus(
                    fans: [.init(index: 0, actualRPM: actual, targetRPM: target,
                                 minRPM: 2000, maxRPM: 6000, mode: "manual")],
                    temperatures: ["Tp01": core, "Tp0W": hotspot ?? core + 8])
        }
    }

    @Test("Leaves the fans to Apple Auto while cool, then controls them under heat")
    func automatic() {
        let rig = Rig()
        rig.monitor.setMode(.automatic)
        rig.run(seconds: 2)
        #expect(rig.last == .system)

        rig.locked { rig.core = 80 }
        rig.run(seconds: 3)
        // Halfway up the 70–90°C curve: 2000 + 0.5 × 4000.
        #expect(rig.last == .rpm(4000))
    }

    @Test("Ticks at the sensor cadence while Apple Auto has the fans")
    func idleCadence() {
        let rig = Rig()
        rig.monitor.setMode(.automatic)
        rig.run(seconds: 2)
        #expect(rig.monitor.currentTickInterval == 1)

        rig.locked { rig.core = 80 }
        rig.run(seconds: 2)
        #expect(rig.monitor.currentTickInterval == 0.1)

        rig.monitor.setMode(.paused)
        rig.run(seconds: 1)
        #expect(rig.monitor.currentTickInterval == 1)
    }

    @Test("A glitched reading holds the last target instead of dropping to Apple Auto")
    func glitch() {
        let rig = Rig()
        rig.monitor.setMode(.automatic)
        rig.locked { rig.core = 80 }
        rig.run(seconds: 3)
        let before = rig.targets.count
        rig.locked { rig.core = 4.3 }
        rig.run(seconds: 2)
        rig.locked { rig.core = 80 }
        rig.run(seconds: 2)
        #expect(rig.targets.count == before)
        #expect(rig.last == .rpm(4000))
    }

    @Test("Lost sensors hand over to Apple Auto after a grace period and recover")
    func sensorLoss() {
        let rig = Rig()
        rig.monitor.setMode(.automatic)
        rig.locked { rig.core = 80 }
        rig.run(seconds: 3)
        rig.locked { rig.failing = true }
        rig.run(seconds: 3)
        #expect(rig.last == .rpm(4000))
        rig.run(seconds: 3)
        #expect(rig.last == .system)
        rig.locked { rig.failing = false }
        rig.run(seconds: 3)
        #expect(rig.last == .rpm(4000))
    }

    @Test("Paused mode sends nothing; manual mode holds each fan's level")
    func pausedAndManual() {
        let rig = Rig()
        rig.monitor.setMode(.paused)
        rig.locked { rig.core = 85 }
        rig.run(seconds: 3)
        #expect(rig.targets.isEmpty)

        rig.monitor.setMode(.manual(level: 0.25))
        rig.run(seconds: 1)
        #expect(rig.last == .perFan([3000]))
    }

    @Test("A hot hotspot overrides a manual level, then gives it back")
    func manualSafety() {
        let rig = Rig()
        rig.monitor.setMode(.manual(level: 0.25))
        rig.run(seconds: 1)
        rig.locked { rig.hotspot = 110 }
        rig.run(seconds: 3)
        #expect(rig.last == .rpm(6000))
        rig.locked { rig.hotspot = 80 }
        rig.run(seconds: 11)
        #expect(rig.last == .perFan([3000]))
    }

    @Test("Resends when the fans run slower than an accepted target, not faster")
    func resendOnMismatch() {
        let rig = Rig()
        rig.monitor.setMode(.automatic)
        rig.locked { rig.core = 80 }
        rig.run(seconds: 3)
        let before = rig.targets.count
        // macOS takes the fan back and drives its own target.
        rig.locked { rig.fanTarget = 2500 }
        rig.run(seconds: 6)
        #expect(rig.targets.count == before + 1)
        #expect(rig.last == .rpm(4000))

        // Something holding the fan faster is left alone.
        rig.locked { rig.fanTarget = 5500 }
        rig.run(seconds: 10)
        #expect(rig.targets.count == before + 1)
    }
}
