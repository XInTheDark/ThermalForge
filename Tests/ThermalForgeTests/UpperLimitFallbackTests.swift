//
//  UpperLimitFallbackTests.swift
//  ThermalForgeTests
//
//  Unit tests for upper limit thermal safety fallback, 10% delta comparison,
//  max-fan failure latching, and user reset.
//

import Testing
import Foundation
@testable import ThermalForgeCore

private final class MockThermalStatusSource: ThermalStatusSource, @unchecked Sendable {
    private let lock = NSLock()
    private var mockedStatus: ThermalStatus

    init(mockedStatus: ThermalStatus) {
        self.mockedStatus = mockedStatus
    }

    func update(_ status: ThermalStatus) {
        lock.lock()
        mockedStatus = status
        lock.unlock()
    }

    func status() throws -> ThermalStatus {
        lock.lock()
        defer { lock.unlock() }
        return mockedStatus
    }
}

@Suite("Upper Limit Fallback & Max-Fan Lock")
struct UpperLimitFallbackTests {

    private func createStatus(maxTemp: Float, otherSensors: [String: Float] = [:]) -> ThermalStatus {
        var temps: [String: Float] = [
            "TC0P": maxTemp,
            "TG0P": 45.0
        ]
        for (k, v) in otherSensors {
            temps[k] = v
        }
        return ThermalStatus(
            fans: [
                .init(index: 0, actualRPM: 2500, targetRPM: 2500, minRPM: 2000, maxRPM: 6000, mode: "manual")
            ],
            temperatures: temps
        )
    }

    @Test("Parallel check: triggers max-fan lock when delta >= 10%")
    func deltaTriggersMaxFanLock() throws {
        let initialStatus = createStatus(maxTemp: 105.0)
        let mockSource = MockThermalStatusSource(mockedStatus: initialStatus)

        // Curve with ceiling at 80, but at 60C it commands ~0.3 (30%)
        let monitor = ThermalMonitor(
            fanControl: mockSource,
            profile: FanProfile.default,
            safetyLimitTemp: 105.0
        )

        var breachedTemp: Float?
        var breachedLimit: Float?
        monitor.onSafetyLimitBreached = { temp, limit in
            breachedTemp = temp
            breachedLimit = limit
        }

        var appliedCommands: [FanCommand] = []
        monitor.onFanCommand = { cmd in
            appliedCommands.append(cmd)
        }

        // Target calculation for 60°C is ~0.3
        let targetAt60 = monitor.calculateProfileTargetPercent(status: initialStatus, peakTemp: 60.0)
        #expect(targetAt60 < 0.90) // delta = 1.0 - targetAt60 > 0.10

        // Start monitor
        monitor.start(interval: 0.05)
        Thread.sleep(forTimeInterval: 0.15)
        monitor.stop()

        #expect(monitor.isSafetyLockedAtMax == true)
        #expect(monitor.state == .safetyOverride)
        #expect(appliedCommands.contains(.safetyMax))
        #expect(breachedTemp == 105.0)
        #expect(breachedLimit == 105.0)
    }

    @Test("Watchdog removed: does NOT clear lock when machine cools down")
    func lockPersistsAfterCooling() throws {
        let hotStatus = createStatus(maxTemp: 106.0)
        let mockSource = MockThermalStatusSource(mockedStatus: hotStatus)

        let monitor = ThermalMonitor(
            fanControl: mockSource,
            profile: FanProfile.default,
            safetyLimitTemp: 105.0
        )

        monitor.start(interval: 0.05)
        Thread.sleep(forTimeInterval: 0.12)

        #expect(monitor.isSafetyLockedAtMax == true)

        // Cool the machine down to 40°C
        mockSource.update(createStatus(maxTemp: 40.0))
        Thread.sleep(forTimeInterval: 0.12)
        monitor.stop()

        // Fans MUST remain locked at max without auto-clearing
        #expect(monitor.isSafetyLockedAtMax == true)
        #expect(monitor.state == .safetyOverride)
    }

    @Test("User retry clears the max-fan lock")
    func userRetryClearsLock() throws {
        let hotStatus = createStatus(maxTemp: 105.0)
        let mockSource = MockThermalStatusSource(mockedStatus: hotStatus)

        let monitor = ThermalMonitor(
            fanControl: mockSource,
            profile: FanProfile.default,
            safetyLimitTemp: 105.0
        )

        monitor.start(interval: 0.05)
        Thread.sleep(forTimeInterval: 0.12)
        monitor.stop()

        #expect(monitor.isSafetyLockedAtMax == true)

        monitor.clearFaultForUserRetry()
        Thread.sleep(forTimeInterval: 0.05)

        #expect(monitor.isSafetyLockedAtMax == false)
        #expect(monitor.state == .idle)
    }

    @Test("Any sensor triggers upper limit even if CPU is low")
    func anySensorBreachesUpperLimit() throws {
        // CPU is at a cool 50°C, but another sensor (e.g. SSD or battery or diode) is 106°C
        let status = createStatus(maxTemp: 50.0, otherSensors: ["TH0P": 106.0])
        let mockSource = MockThermalStatusSource(mockedStatus: status)

        let monitor = ThermalMonitor(
            fanControl: mockSource,
            profile: FanProfile.default,
            safetyLimitTemp: 105.0
        )

        var breached = false
        monitor.onSafetyLimitBreached = { _, _ in
            breached = true
        }

        monitor.start(interval: 0.05)
        Thread.sleep(forTimeInterval: 0.15)
        monitor.stop()

        #expect(breached == true)
        #expect(monitor.isSafetyLockedAtMax == true)
        #expect(monitor.state == .safetyOverride)
    }

    @Test("Manual control also locks when a non-CPU/GPU sensor reaches the limit")
    func manualAnySensorBreachesUpperLimit() throws {
        let status = createStatus(maxTemp: 50.0, otherSensors: ["TH0P": 106.0])
        let mockSource = MockThermalStatusSource(mockedStatus: status)
        let monitor = ThermalMonitor(
            fanControl: mockSource,
            profile: FanProfile.default,
            safetyLimitTemp: 105.0
        )

        var commands: [FanCommand] = []
        monitor.onFanCommand = { commands.append($0) }
        monitor.setManualControl(true)
        monitor.start(interval: 0.05)
        Thread.sleep(forTimeInterval: 0.15)
        monitor.stop()

        #expect(monitor.isSafetyLockedAtMax == true)
        #expect(commands.contains(.safetyMax))
    }

    @Test("Configurable threshold updates dynamically")
    func dynamicThresholdUpdate() throws {
        let status = createStatus(maxTemp: 106.0)
        let mockSource = MockThermalStatusSource(mockedStatus: status)

        let monitor = ThermalMonitor(
            fanControl: mockSource,
            profile: FanProfile.default,
            safetyLimitTemp: 105.0
        )

        // Increase threshold to 110°C
        monitor.updateSafetyLimit(110.0)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(monitor.safetyLimitTemp == 110.0)

        var breached = false
        monitor.onSafetyLimitBreached = { _, _ in
            breached = true
        }

        monitor.start(interval: 0.05)
        Thread.sleep(forTimeInterval: 0.12)
        monitor.stop()

        // 106°C is below 110°C, so it should NOT breach the safety limit
        #expect(breached == false)
        #expect(monitor.isSafetyLockedAtMax == false)
    }
}
