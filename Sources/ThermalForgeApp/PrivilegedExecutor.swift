//
//  PrivilegedExecutor.swift
//  ThermalForge
//
//  Sends fan commands to the privileged daemon via Unix socket.
//  No password prompts — the daemon runs as root via launchd.
//

import Foundation
import ThermalForgeCore

final class PrivilegedExecutor: @unchecked Sendable {
    private let client = DaemonClient()

    func execute(_ command: FanCommand) throws {
        try client.executeRetryingDisconnect(command)
    }

    /// Apply every command of a target, in fan order.
    func apply(_ target: FanTarget) throws {
        for command in target.commands {
            try execute(command)
        }
    }

    func readState() throws -> DaemonHoldState {
        try client.readState()
    }
}
