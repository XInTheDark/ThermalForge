import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Fan actuator")
struct FanActuatorTests {
    final class Harness: @unchecked Sendable {
        let queue = DispatchQueue(label: "actuator-test")
        let lock = NSLock()
        var time: TimeInterval = 100
        var sent: [FanTarget] = []
        var failNext = 0
        var healths: [FanActuator.Health] = []
        lazy var actuator: FanActuator = {
            let actuator = FanActuator(queue: queue, now: { [unowned self] in
                lock.lock(); defer { lock.unlock() }
                return time
            }) { [unowned self] target in
                lock.lock(); defer { lock.unlock() }
                sent.append(target)
                if failNext > 0 {
                    failNext -= 1
                    throw DaemonError.notRunning
                }
            }
            actuator.onHealthChange = { [unowned self] health in
                lock.lock(); healths.append(health); lock.unlock()
            }
            return actuator
        }()

        func advance(_ seconds: TimeInterval) {
            lock.lock(); time += seconds; lock.unlock()
        }

        /// Let queued work (and any follow-up pumps it triggers) finish.
        func drain() {
            for _ in 0..<5 { queue.sync {} }
        }

        var sentTargets: [FanTarget] {
            lock.lock(); defer { lock.unlock() }
            return sent
        }
    }

    @Test("Sends a target once and skips repeats and small RPM steps")
    func dedupe() {
        let h = Harness()
        h.actuator.request(.rpm(3000))
        h.drain()
        h.advance(1)
        h.actuator.request(.rpm(3000))
        h.actuator.request(.rpm(3010))
        h.drain()
        #expect(h.sentTargets == [.rpm(3000)])
        #expect(h.actuator.confirmedTarget == .rpm(3000))
    }

    @Test("Ramp updates are spaced out; mode changes are not")
    func spacing() {
        let h = Harness()
        h.actuator.request(.rpm(3000))
        h.drain()
        h.advance(0.1)
        h.actuator.request(.rpm(3200))
        h.drain()
        #expect(h.sentTargets == [.rpm(3000)])
        h.advance(0.2)
        h.actuator.poll()
        h.drain()
        #expect(h.sentTargets == [.rpm(3000), .rpm(3200)])
        h.advance(0.01)
        h.actuator.request(.system)
        h.drain()
        #expect(h.sentTargets.last == .system)
    }

    @Test("Failures are retried with backoff and never give up")
    func retries() {
        let h = Harness()
        h.failNext = 3
        h.actuator.request(.rpm(4000))
        h.drain()
        #expect(h.sentTargets.count == 1)
        #expect(h.actuator.confirmedTarget == nil)

        // Not before the 0.5 s backoff.
        h.advance(0.3); h.actuator.poll(); h.drain()
        #expect(h.sentTargets.count == 1)
        h.advance(0.3); h.actuator.poll(); h.drain()
        #expect(h.sentTargets.count == 2)
        #expect(h.actuator.currentHealth != .ok)

        h.advance(1.1); h.actuator.poll(); h.drain()
        h.advance(2.1); h.actuator.poll(); h.drain()
        #expect(h.sentTargets.count == 4)
        #expect(h.actuator.confirmedTarget == .rpm(4000))
        #expect(h.actuator.currentHealth == .ok)
        #expect(h.healths.last == .ok)
    }

    @Test("Invalidate resends; pause stops sending until resumed")
    func invalidateAndPause() {
        let h = Harness()
        h.actuator.request(.rpm(3000))
        h.drain()
        h.advance(1)
        h.actuator.invalidate()
        h.drain()
        #expect(h.sentTargets == [.rpm(3000), .rpm(3000)])

        h.actuator.setPaused(true)
        h.advance(1)
        h.actuator.request(.rpm(5000))
        h.drain()
        #expect(h.sentTargets.count == 2)
        h.actuator.setPaused(false)
        h.drain()
        #expect(h.sentTargets.last == .rpm(5000))
    }

    @Test("Targets expand into daemon commands")
    func commands() {
        #expect(FanTarget.system.commands == [.resetAuto])
        #expect(FanTarget.rpm(3000).commands == [.setRPM(3000)])
        #expect(FanTarget.perFan([2500, 2600]).commands == [.setFan(index: 0, rpm: 2500), .setFan(index: 1, rpm: 2600)])
    }
}
