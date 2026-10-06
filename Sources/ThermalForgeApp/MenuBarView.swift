//
//  MenuBarView.swift
//  ThermalForge
//
//  Menu bar dropdown content.
//

import AppKit
import SwiftUI
import ThermalForgeCore

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            banners
            if let snapshot = appState.snapshot {
                StatusSection(snapshot: snapshot)
                Divider().padding(.vertical, 6)
                TemperatureSection(status: snapshot.status)
            } else {
                Text("Reading sensors…")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            Divider().padding(.vertical, 6)
            ControlSection()
            Divider().padding(.vertical, 6)
            footer
        }
        .frame(width: 300)
        .background(WindowVisibilityReader { appState.setMenuVisible($0) })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("ThermalForge")
                .font(.headline)
            Spacer()
            ModeBadge()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var banners: some View {
        if appState.daemonInstalled == false {
            Banner(style: .warning, title: "Fan control needs setup", systemImage: "lock.shield",
                   message: "Install the background service once to control fans without repeated password prompts.",
                   actionTitle: "Install Service", action: { appState.installDaemon() })
        } else if appState.daemonUnreachable {
            Banner(style: .error, title: "Fan control unavailable", systemImage: "exclamationmark.octagon.fill",
                   message: "The background service isn't responding. macOS keeps controlling the fans until it's back.",
                   actionTitle: "Restart Service", action: { appState.restartDaemon() })
        } else if let daemonVersion = appState.daemonVersionMismatch {
            Banner(style: .warning, title: "Update the background service", systemImage: "arrow.triangle.2.circlepath",
                   message: "It's running \(daemonVersion); the app is \(ThermalForgeVersion.current). Fan control may not behave as described until they match.",
                   actionTitle: AppState.bundledCLIPath == nil ? nil : "Update Service",
                   action: { appState.installDaemon() },
                   command: AppState.bundledCLIPath == nil ? "sudo thermalforge install" : nil)
        }

        if let other = appState.competingFanApp, !appState.appleAutoSelected {
            Banner(style: .warning, title: "\(other) is also controlling the fans", systemImage: "exclamationmark.2",
                   message: "Two fan controllers overwrite each other's speeds. Quit \(other) or switch ThermalForge to Apple Auto.")
        }
        if let hold = appState.externalHold {
            Banner(style: .warning, title: "Fans held from Terminal", systemImage: "terminal.fill",
                   message: Self.describe(hold) + " Choose a mode below to take over.")
        }
        if let issue = appState.snapshot?.sensorIssue {
            Banner(style: .warning, title: "Sensors unavailable", systemImage: "thermometer.medium.slash",
                   message: "macOS has the fans because \(issue). Control resumes automatically when readings return.")
        }
        if appState.loopStalled {
            Banner(style: .warning, title: "Control loop paused", systemImage: "pause.circle",
                   message: "macOS has the fans until the control loop catches up.")
        }
        if case .retrying(let failures, _) = appState.commandHealth, !appState.daemonUnreachable,
           appState.daemonInstalled != false {
            Banner(style: .warning, title: "Retrying fan commands", systemImage: "arrow.clockwise",
                   message: "The last \(failures) fan commands didn't go through. ThermalForge keeps retrying and stays in your chosen mode.")
        }
        if appState.snapshot?.safetyOverride == true, let snapshot = appState.snapshot {
            Banner(style: .error, title: "Full speed: hotspot \(formatTemp(snapshot.status.safetyPeakTemp))",
                   systemImage: "flame.fill",
                   message: "A silicon hotspot reached the \(formatTemp(Float(appState.safetyLimitTemp))) safety limit. Fans return to your profile once it cools.")
        }
        if appState.daemonVersionMismatch == nil, let update = appState.availableUpdate {
            UpdateAvailableBanner(update: update, onDismiss: { appState.dismissUpdate() })
        }
    }

    private var footer: some View {
        HStack {
            Button {
                PreferencesWindowController.shared.show(appState: appState)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func formatTemp(_ celsius: Float) -> String {
        TemperatureFormat.string(celsius, fahrenheit: appState.useFahrenheit, decimals: 0)
    }

    static func describe(_ hold: DaemonHoldState) -> String {
        let parts = (hold.command ?? "").split(separator: " ").map(String.init)
        switch parts.first {
        case "max": return "Fans are held at maximum."
        case "set" where parts.count > 1: return "Fans are held at about \(parts[1]) RPM."
        case "setfan" where parts.count > 2: return "Fan \(parts[1]) is held at about \(parts[2]) RPM."
        default: return "Fans are held manually."
        }
    }
}

// MARK: - Mode badge

private struct ModeBadge: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var text: String {
        if appState.externalHold != nil { return "Terminal" }
        if appState.snapshot?.safetyOverride == true { return "Safety" }
        if let manual = appState.manualPercent { return "Manual \(Int(manual))%" }
        if appState.appleAutoSelected { return "Apple Auto" }
        return appState.currentProfile.name
    }

    private var icon: String {
        if appState.snapshot?.safetyOverride == true { return "exclamationmark.triangle.fill" }
        if appState.manualPercent != nil { return "hand.raised.fill" }
        if appState.appleAutoSelected || appState.externalHold != nil { return "apple.logo" }
        return "fan.fill"
    }

    private var color: Color {
        if appState.snapshot?.safetyOverride == true { return .red }
        if appState.manualPercent != nil || appState.externalHold != nil { return .orange }
        if appState.appleAutoSelected { return .secondary }
        return .accentColor
    }
}

// MARK: - Status

private struct StatusSection: View {
    @EnvironmentObject var appState: AppState
    let snapshot: MonitorSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(TemperatureFormat.string(appState.menuTemperature ?? snapshot.status.nominalPeakTemp,
                                              fahrenheit: appState.useFahrenheit, decimals: 0))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(TemperatureFormat.color(snapshot.status.nominalPeakTemp))
                VStack(alignment: .leading, spacing: 0) {
                    Text("CPU/GPU core")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if appState.smoothingEnabled {
                        Text("smoothed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(snapshot.status.fans, id: \.index) { fan in
                        Text(fanLabel(fan))
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            }

            Label(driverText, systemImage: driverIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func fanLabel(_ fan: ThermalStatus.FanStatus) -> String {
        let prefix = snapshot.status.fans.count > 1 ? "Fan \(fan.index + 1) " : ""
        guard fan.actualRPM > 0 else { return prefix + "Off" }
        let percent = fan.actualPercent.map { $0 == 0 ? "min" : "\($0)%" } ?? "—"
        return "\(prefix)\(fan.actualRPM) RPM · \(percent)"
    }

    private var driverText: String {
        let temp = { (c: Float) in TemperatureFormat.string(c, fahrenheit: appState.useFahrenheit, decimals: 0) }
        if appState.externalHold != nil { return "Following the Terminal hold." }
        if snapshot.sensorIssue != nil { return "Apple Auto until sensors recover." }
        switch snapshot.mode {
        case .paused:
            return "Waiting for the background service."
        case .manual:
            return snapshot.target.map { "Holding \($0) until you choose a profile." } ?? "Holding a manual speed."
        case .automatic:
            break
        }
        if snapshot.profile.curve.handsOff { return "macOS controls the fans." }
        guard let output = snapshot.output else { return "Starting…" }
        let (engageAt, _) = appState.controlSettings.thresholds(for: snapshot.profile.curve)
        switch output.driver {
        case .appleAuto:
            return appState.handBackWhenCool
                ? "Apple Auto while cool. \(snapshot.profile.name) takes over above \(temp(engageAt))."
                : "Starting…"
        case .standby: return "Minimum speed — below the curve."
        case .curve: return "Following the \(snapshot.profile.name) curve."
        case .rising: return "Temperature rising — responding early."
        case .sustained: return "Sustained load — +\(Int((output.sustainedTrim * 100).rounded()))% to hold \(temp(snapshot.profile.curve.targetTemp))."
        case .battery: return "Battery at \(temp(snapshot.status.batteryTemp ?? 0)) — cooling the battery."
        case .pressure: return "macOS reports \(snapshot.pressure.description.lowercased()) thermal pressure."
        case .safety: return "Hotspot safety override — full speed."
        }
    }

    private var driverIcon: String {
        guard let output = snapshot.output else { return "info.circle" }
        switch output.driver {
        case .appleAuto: return "apple.logo"
        case .standby, .curve: return "chart.xyaxis.line"
        case .rising: return "arrow.up.right"
        case .sustained: return "clock.arrow.circlepath"
        case .battery: return "battery.75percent"
        case .pressure: return "gauge.with.dots.needle.67percent"
        case .safety: return "flame.fill"
        }
    }
}

private struct TemperatureSection: View {
    @EnvironmentObject var appState: AppState
    let status: ThermalStatus

    var body: some View {
        let rows: [(String, Float?, String?)] = [
            ("CPU", status.cpuCoreMaxTemp, nil),
            ("GPU", status.gpuCoreMaxTemp, nil),
            ("Hotspot", status.siliconHotspotTemp, "Hottest silicon junction. Drives the safety override, not the curve."),
            ("Battery", status.batteryTemp, nil),
            ("SSD", peak(["TH"]), nil),
            ("Memory", peak(["TR", "Tm", "TM"]), nil),
            ("Ambient", peak(["TA", "Ta"]), nil),
        ]
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            ForEach(rows.filter { $0.1 != nil }, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .help(row.2 ?? "")
                    Spacer()
                    Text(TemperatureFormat.string(row.1!, fahrenheit: appState.useFahrenheit, decimals: 1))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(TemperatureFormat.color(row.1!))
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func peak(_ prefixes: [String]) -> Float? {
        status.temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }.values.max()
    }
}

// MARK: - Control

private struct ControlSection: View {
    @EnvironmentObject var appState: AppState

    enum Mode: Hashable { case profile, appleAuto, manual }

    private var mode: Mode {
        if appState.manualPercent != nil { return .manual }
        if appState.appleAutoSelected { return .appleAuto }
        return .profile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: Binding(get: { mode }, set: select)) {
                Text("Profile").tag(Mode.profile)
                Text("Apple Auto").tag(Mode.appleAuto)
                Text("Manual").tag(Mode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .profile: ProfileControls()
            case .appleAuto:
                Text("macOS controls the fans. ThermalForge only monitors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .manual: ManualControls()
            }
        }
        .padding(.horizontal, 12)
    }

    private func select(_ newMode: Mode) {
        switch newMode {
        case .profile: appState.resumeProfiles()
        case .appleAuto: appState.selectAppleAuto()
        case .manual:
            // Start from the current speed so switching causes no jump.
            let current = appState.snapshot?.status.fans.compactMap(\.actualPercent).max() ?? 50
            appState.manualDraftPercent = Double(current)
            appState.applyManual(Double(current))
        }
    }
}

private struct ProfileControls: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Label("Battery", systemImage: "battery.75percent")
                        .foregroundStyle(appState.usingExternalPower ? .secondary : .primary)
                    profilePicker(selection: appState.batteryProfileID, select: appState.selectBatteryProfile)
                }
                GridRow {
                    Label("Adapter", systemImage: "powerplug")
                        .foregroundStyle(appState.usingExternalPower ? .primary : .secondary)
                    profilePicker(selection: appState.adapterProfileID, select: appState.selectAdapterProfile)
                }
            }
            .font(.callout)

            Text(appState.currentProfile.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            FanCurvePreview(profile: appState.currentProfile,
                            settings: appState.controlSettings,
                            externalPower: appState.usingExternalPower,
                            liveTemp: appState.snapshot?.controlTemp,
                            liveLevel: appState.snapshot?.output.flatMap { $0.engaged ? $0.level : nil },
                            fahrenheit: appState.useFahrenheit)
        }
    }

    private func profilePicker(selection: String, select: @escaping (FanProfile) -> Void) -> some View {
        Picker("", selection: Binding(
            get: { selection },
            set: { id in select(FanProfile.selectable(id: id)) }
        )) {
            ForEach(FanProfile.available) { profile in
                Text(profile.name).tag(profile.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

private struct ManualControls: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Slider(value: $appState.manualDraftPercent, in: 0...100, step: 1) { editing in
                    if !editing { appState.applyManual(appState.manualDraftPercent) }
                }
                .accessibilityLabel("Manual fan level")
                .accessibilityValue("\(Int(appState.manualDraftPercent)) percent")
                Text("\(Int(appState.manualDraftPercent))%")
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            .disabled(!appState.canApplyManual)
            Text("0% is the fans' minimum speed. The hotspot safety override still applies.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Curve preview

private struct FanCurvePreview: View {
    let profile: FanProfile
    let settings: ControlSettings
    let externalPower: Bool
    let liveTemp: Float?
    let liveLevel: Float?
    let fahrenheit: Bool

    var body: some View {
        let curve = profile.curve
        let (engageAt, _) = settings.thresholds(for: curve)
        let transform = externalPower ? settings.adapterTransform : settings.batteryTransform
        let lowTemp = min(engageAt, curve.points.first?.temp ?? engageAt) - 8
        let highTemp = max(curve.fullSpeedTemp, curve.points.last?.temp ?? engageAt) + 4

        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in
                let plot = CGRect(x: 0, y: 4, width: size.width, height: size.height - 8)
                func point(_ temp: Float, _ level: Float) -> CGPoint {
                    let x = CGFloat((temp - lowTemp) / (highTemp - lowTemp))
                    return CGPoint(x: plot.minX + x * plot.width, y: plot.maxY - CGFloat(level) * plot.height)
                }

                // Grid lines at 25% steps.
                for step in 1...3 {
                    var line = Path()
                    let y = plot.maxY - CGFloat(step) / 4 * plot.height
                    line.move(to: CGPoint(x: plot.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                }

                // Apple Auto region below the takeover temperature.
                if settings.handBackWhenCool {
                    let x = point(engageAt, 0).x
                    context.fill(Path(CGRect(x: plot.minX, y: plot.minY, width: max(x - plot.minX, 0), height: plot.height)),
                                 with: .color(.secondary.opacity(0.08)))
                }

                var path = Path()
                let steps = 60
                for index in 0...steps {
                    let temp = lowTemp + (highTemp - lowTemp) * Float(index) / Float(steps)
                    let engaged = !settings.handBackWhenCool || temp >= engageAt
                    let level = engaged ? transform.apply(to: curve.level(at: temp)) : 0
                    let p = point(temp, level)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 2)

                var base = Path()
                base.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                base.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                context.stroke(base, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

                if let liveTemp {
                    let clamped = min(max(liveTemp, lowTemp), highTemp)
                    var marker = Path()
                    let x = point(clamped, 0).x
                    marker.move(to: CGPoint(x: x, y: plot.minY))
                    marker.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(marker, with: .color(.orange.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    if let liveLevel {
                        let dot = point(clamped, liveLevel)
                        context.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)),
                                     with: .color(.orange))
                    }
                }
            }
            .frame(height: 70)

            HStack {
                Text(TemperatureFormat.string(lowTemp, fahrenheit: fahrenheit, decimals: 0))
                Spacer()
                Text("takeover \(TemperatureFormat.string(engageAt, fahrenheit: fahrenheit, decimals: 0))")
                Spacer()
                Text(TemperatureFormat.string(highTemp, fahrenheit: fahrenheit, decimals: 0))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            Text("Steady-temperature estimate (min → max RPM). Live speed also follows smoothing, ramp limits, sustained load, rising temperature, battery, and macOS thermal pressure.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared pieces

enum TemperatureFormat {
    static func string(_ celsius: Float, fahrenheit: Bool, decimals: Int) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: "%.\(decimals)f°%@", value, fahrenheit ? "F" : "C")
    }

    /// Color thresholds, always in °C.
    static func color(_ celsius: Float) -> Color {
        if celsius >= 95 { return .red }
        if celsius >= 85 { return .orange }
        if celsius >= 70 { return .yellow }
        return .primary
    }
}

private struct Banner: View {
    enum Style { case warning, error }

    let style: Style
    let title: String
    let systemImage: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var command: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(style == .error ? .red : .orange)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }

    private var tint: Color { style == .error ? .red : .orange }
}

/// A newer ThermalForge release exists. Informational and dismissible per version.
private struct UpdateAvailableBanner: View {
    let update: AvailableUpdate
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Update available", systemImage: "arrow.down.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.blue)
            Text("ThermalForge \(update.version) is available. You have \(ThermalForgeVersion.current).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("brew upgrade thermalforge && sudo thermalforge install")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            HStack {
                if let url = URL(string: update.url) {
                    Link("What's new", destination: url)
                        .font(.caption2)
                }
                Spacer()
                Button("Later", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12))
    }
}

// MARK: - Window visibility

/// Reports whether the hosting window is on screen. The menu bar window stays
/// alive while closed, so SwiftUI's appear/disappear callbacks don't track it.
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onChange: onChange)
    }

    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { onChange(false); return }
            observers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    }
                }
            report()
        }

        private func report() {
            guard let window else { return }
            onChange(window.isVisible && window.occlusionState.contains(.visible))
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
