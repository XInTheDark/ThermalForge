//
//  PreferencesView.swift
//  ThermalForgeApp
//
//  Dedicated preferences window view with interactive slider controls.
//

import SwiftUI
import ThermalForgeCore

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("ThermalForge Settings")
                    .font(.headline)
            }
            .padding(.bottom, 2)

            Divider()

            // Temperature Smoothing
            VStack(alignment: .leading, spacing: 8) {
                Text("TEMPERATURE SMOOTHING")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Toggle("Smooth temperature readings", isOn: $appState.temperatureSmoothingEnabled)
                    .fontWeight(.medium)

                Text("Symmetric Exponential Moving Average (EMA) dampens instantaneous core spikes without ratchet bias, using distinct time constants for fan ramp-up vs ramp-down.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if appState.temperatureSmoothingEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Ramp-up smoothing window")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.1f s", appState.rampUpWindowSeconds))
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $appState.rampUpWindowSeconds, in: 3.0...20.0, step: 1.0)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Ramp-down smoothing window")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.1f s", appState.rampDownWindowSeconds))
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $appState.rampDownWindowSeconds, in: 10.0...60.0, step: 2.0)
                        }

                        Text("Responsive \(String(format: "%.0f", appState.rampUpWindowSeconds))s window while accelerating; extended \(String(format: "%.0f", appState.rampDownWindowSeconds))s window while decelerating to match chassis thermal mass and prevent fan speed hunting.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }

            Divider()

            // Refresh Rates
            VStack(alignment: .leading, spacing: 8) {
                Text("REFRESH RATES")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sensor snapshot interval")
                            .font(.subheadline)
                        Spacer()
                        Text(formatSensorInterval(appState.sensorRefreshInterval))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appState.sensorRefreshInterval, in: 0.5...5.0, step: 0.5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Control loop interval")
                            .font(.subheadline)
                        Spacer()
                        Text(formatControlInterval(appState.controlLoopInterval))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appState.controlLoopInterval, in: 0.05...0.50, step: 0.025)
                }

                Text("Defaults: 1.0s sensor snapshot, 100ms fan control loop.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Thermal Safety Limit
            VStack(alignment: .leading, spacing: 8) {
                Text("THERMAL SAFETY LIMIT")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Upper limit threshold")
                            .font(.subheadline)
                        Spacer()
                        Text(formatSafetyLimit(appState.safetyLimitTemp))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appState.safetyLimitTemp, in: 90.0...115.0, step: 1.0)
                }

                Text("If any sensor reaches this limit and exceeds the profile output by ≥10%, fans immediately lock at 100% maximum RPM and trigger a desktop alert. Default: 105°C.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Hybrid Control (Low Temperature Regime)
            VStack(alignment: .leading, spacing: 8) {
                Text("HYBRID CONTROL (LOW TEMPERATURE REGIME)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Toggle("Enable low-temperature hybrid mode", isOn: $appState.lowTempRegimeEnabled)
                    .fontWeight(.medium)

                HStack {
                    Text("Minimum takeover temperature")
                        .font(.subheadline)
                    Spacer()
                    TextField("", value: lowTempBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                        .multilineTextAlignment(.trailing)
                    Text(appState.useFahrenheit ? "°F" : "°C")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Stepper("", value: lowTempBinding, in: appState.useFahrenheit ? 110...185 : 45...85, step: 1)
                        .labelsHidden()
                }
                .disabled(!appState.lowTempRegimeEnabled)
                .opacity(appState.lowTempRegimeEnabled ? 1.0 : 0.5)

                Text(appState.lowTempRegimeEnabled
                     ? "Below this threshold, fan control is handed to macOS (Apple Auto) so fans stay silent (0 RPM). ThermalForge only takes control when CPU temperature rises above this threshold. Default: 60°C (140°F)."
                     : "When disabled, ThermalForge always controls the fans at minimum hardware RPM or higher, actively cooling the heatsink without returning to Apple Auto.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // General
            VStack(alignment: .leading, spacing: 8) {
                Text("GENERAL")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Toggle("Display Fahrenheit (°F)", isOn: $appState.useFahrenheit)
                Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                Toggle("Adapter cooling boost (+5% shift, ×1.10 target on AC)", isOn: $appState.adapterBoostEnabled)
            }

            Spacer()
            }
            .padding(20)
        }
        .frame(width: 440, height: 720)
    }

    private var lowTempBinding: Binding<Double> {
        Binding(
            get: {
                if appState.useFahrenheit {
                    return round(appState.lowTempThreshold * 9 / 5 + 32)
                } else {
                    return round(appState.lowTempThreshold)
                }
            },
            set: { newValue in
                if appState.useFahrenheit {
                    let celsius = (newValue - 32) * 5 / 9
                    appState.lowTempThreshold = celsius
                } else {
                    appState.lowTempThreshold = newValue
                }
            }
        )
    }

    private func formatSafetyLimit(_ tempC: Double) -> String {
        if appState.useFahrenheit {
            let tempF = Int(round(tempC * 9 / 5 + 32))
            return "\(tempF) °F"
        } else {
            return "\(Int(round(tempC))) °C"
        }
    }

    private func formatSensorInterval(_ interval: Double) -> String {
        if interval < 1.0 {
            return "\(Int(interval * 1000)) ms"
        }
        return interval == floor(interval) ? "\(Int(interval)).0 s" : "\(String(format: "%.1f", interval)) s"
    }

    private func formatControlInterval(_ interval: Double) -> String {
        return "\(Int(interval * 1000)) ms"
    }
}
