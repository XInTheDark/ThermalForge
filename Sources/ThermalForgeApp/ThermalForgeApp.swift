//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import SwiftUI
import ThermalForgeCore

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
        }

        NotificationManager.shared.requestAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reset fans on quit so the daemon doesn't hold stale APP settings — but
        // ONLY if the app owns the hold. A CLI hold (`sudo thermalforge max`) is the
        // user's deliberate, unsupervised choice; quitting the menu bar app must not
        // destroy it — that's the v0.1.7 arbitration feature. Synchronous on purpose:
        // the process is exiting, so an async write would be dropped; both calls are
        // bounded by the sendRaw timeout.
        let client = DaemonClient()
        if let state = try? client.readState(), state.owner == "app" {
            _ = try? client.execute(.resetAuto)
        }
        // owner == "cli" → leave the CLI hold alone; owner == "none" → nothing to reset.
    }
}

@main
struct ThermalForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(
                status: MenuBarLabel.Status(appState.snapshot),
                temperature: appState.menuTemperature,
                fahrenheit: appState.useFahrenheit,
                needsAttention: appState.daemonVersionMismatch != nil || appState.daemonUnreachable
                    || appState.daemonInstalled == false || appState.commandHealth != .ok
            )
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    enum Status {
        case appleAuto, controlling, safety

        init(_ snapshot: MonitorSnapshot?) {
            guard let snapshot else { self = .appleAuto; return }
            if snapshot.safetyOverride { self = .safety; return }
            switch snapshot.target {
            case .rpm?, .perFan?: self = .controlling
            default: self = .appleAuto
            }
        }
    }

    let status: Status
    let temperature: Float?
    var fahrenheit: Bool = false
    var needsAttention: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .overlay(alignment: .topTrailing) {
                    if needsAttention {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
            if let tempC = temperature {
                let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                Text("\(Int(display.rounded()))°")
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var iconName: String {
        switch status {
        case .safety: return "exclamationmark.triangle.fill"
        case .controlling: return "fan.fill"
        case .appleAuto: return "fan"
        }
    }
}
