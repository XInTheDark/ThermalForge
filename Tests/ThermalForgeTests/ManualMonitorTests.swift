import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Manual control monitoring")
struct ManualMonitorTests {
    private static let immediateProfile = FanProfile(
        id: "test", name: "Test",
        curve: .init(sustainedTriggerSec: 0, instantEngage: true)
    )

    @Test("Manual hold survives profile refresh and power changes while sensors keep updating")
    func pausesCurveUntilExplicitProfileSelection() throws {
        let source = SensorFixture()
        let monitor = ThermalMonitor(fanControl: source, profile: Self.immediateProfile,
                                     sensorRefreshInterval: 0.05, controlLoopInterval: 0.05)
        let updates = DispatchSemaphore(value: 0)
        let commands = CommandRecorder()
        monitor.onUpdate = { _, _, _ in updates.signal() }
        monitor.onFanCommand = { commands.append($0) }
        monitor.setManualControl(true)
        monitor.start()
        defer { monitor.stop() }
        try #require(updates.wait(timeout: .now() + 2) == .success)
        monitor.updatePowerSource(.external)
        monitor.updateProfiles(battery: Self.immediateProfile, adapter: Self.immediateProfile,
                               batteryTransform: .identity, adapterTransform: .adapterDefault)
        monitor.requestReapply()
        try #require(updates.wait(timeout: .now() + 2) == .success)
        #expect(commands.values.isEmpty)
        #expect(monitor.hasRecentControlTick())

        monitor.switchProfile(Self.immediateProfile)
        try #require(commands.received.wait(timeout: .now() + 2) == .success)
        #expect(commands.values.first?.isHold == true)
    }

    @Test("Sensor failure and critical heat release manual control once and keep it latched off",
          arguments: [Failure.missingSensors, .snapshotFailed, .overheated])
    func emergencyHandback(failure: Failure) throws {
        let source = SensorFixture()
        let monitor = ThermalMonitor(fanControl: source, profile: Self.immediateProfile,
                                     sensorRefreshInterval: 0.05, controlLoopInterval: 0.05)
        let updates = DispatchSemaphore(value: 0)
        let commands = CommandRecorder()
        monitor.onUpdate = { _, _, _ in updates.signal() }
        monitor.onFanCommand = { commands.append($0) }
        monitor.setManualControl(true)
        monitor.start()
        defer { monitor.stop() }
        try #require(updates.wait(timeout: .now() + 2) == .success)
        source.fail(failure)
        try #require(commands.received.wait(timeout: .now() + 2) == .success)
        if failure == .overheated {
            #expect(commands.values == [.safetyMax])
            #expect(monitor.isSafetyLockedAtMax)
        } else {
            #expect(commands.values == [.resetAuto])
            #expect(monitor.isControlFaultLatched)
        }
        if failure == .overheated {
            #expect(monitor.hasRecentControlTick())
        } else {
            #expect(!monitor.hasRecentControlTick())
        }

        source.fail(nil)
        monitor.requestReapply()
        monitor.updatePowerSource(.battery)
        let drained = DispatchSemaphore(value: 0)
        monitor.setManualControl(false) { drained.signal() }
        try #require(drained.wait(timeout: .now() + 2) == .success)
        if failure == .overheated {
            #expect(monitor.isSafetyLockedAtMax)
            #expect(commands.values == [.safetyMax])
        } else {
            #expect(monitor.isControlFaultLatched)
            #expect(commands.values == [.resetAuto])
        }
    }

    enum Failure: Error {
        case missingSensors, snapshotFailed, overheated
    }

    private final class SensorFixture: ThermalStatusSource {
        private let lock = NSLock()
        private var failure: Failure?

        func fail(_ value: Failure?) {
            lock.lock()
            failure = value
            lock.unlock()
        }

        func status() throws -> ThermalStatus {
            lock.lock()
            defer { lock.unlock() }
            if failure == .snapshotFailed { throw Failure.snapshotFailed }
            return ThermalStatus(
                fans: [.init(index: 0, actualRPM: 4000, targetRPM: 4000,
                             minRPM: 2000, maxRPM: 8000, mode: "manual")],
                temperatures: failure == .missingSensors ? [:] : ["TC0P": failure == .overheated ? 106 : 75]
            )
        }
    }

    private final class CommandRecorder {
        let received = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var commands: [FanCommand] = []

        var values: [FanCommand] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }

        func append(_ command: FanCommand) {
            lock.lock()
            commands.append(command)
            lock.unlock()
            received.signal()
        }
    }
}
