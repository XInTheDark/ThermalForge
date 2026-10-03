//
//  PreferencesView.swift
//  ThermalForgeApp
//
//  Settings window.
//

import SwiftUI
import ThermalForgeCore

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Hand fans back to Apple Auto when cool", isOn: $appState.handBackWhenCool)
                Toggle("Custom takeover temperature", isOn: $appState.customTakeoverEnabled)
                    .disabled(!appState.handBackWhenCool)
                if appState.customTakeoverEnabled && appState.handBackWhenCool {
                    LabeledSlider(title: "Take over at", value: $appState.customTakeoverTemp, range: 50...90, step: 1,
                                  format: temperature)
                }
            } header: {
                Text("Takeover")
            } footer: {
                Text(appState.handBackWhenCool
                     ? "Below the takeover temperature macOS controls the fans, so they can stop completely. Each profile has its own takeover point (\(profileTakeovers)); a custom value replaces it for every profile."
                     : "ThermalForge always controls the fans and keeps them at least at minimum speed.")
            }

            Section {
                Toggle("Adapter cooling boost", isOn: $appState.adapterBoostEnabled)
            } footer: {
                Text("On the power adapter, profile fan levels are multiplied by 1.10 and raised by 5 points.")
            }

            Section {
                LabeledSlider(title: "Hotspot limit", value: $appState.safetyLimitTemp,
                              range: Double(FanProfile.safetyLimitRange.lowerBound)...Double(FanProfile.safetyLimitRange.upperBound),
                              step: 1, format: temperature)
            } header: {
                Text("Safety")
            } footer: {
                Text("If the hottest CPU/GPU silicon sensor stays at this limit for 2 seconds, fans run at full speed until it is 8°C cooler for 10 seconds, then return to your mode. The background service enforces the same limit if the app stops. Default: \(Int(FanProfile.safetyTempThreshold))°C.")
            }

            Section {
                Toggle("Smooth the control temperature", isOn: $appState.smoothingEnabled)
                if appState.smoothingEnabled {
                    LabeledSlider(title: "Rising response", value: $appState.smoothingAttackSeconds, range: 1...15, step: 1,
                                  format: { "\(Int($0)) s" })
                    LabeledSlider(title: "Falling response", value: $appState.smoothingDecaySeconds, range: 5...60, step: 1,
                                  format: { "\(Int($0)) s" })
                }
            } header: {
                Text("Smoothing")
            } footer: {
                Text("Core temperatures jump within a second; the heatsink changes over tens of seconds. A short rising time constant reacts to real load quickly, and a longer falling one keeps fans from chasing every pause. Defaults: \(Int(TemperatureFilter.defaultAttackSeconds)) s and \(Int(TemperatureFilter.defaultDecaySeconds)) s.")
            }

            Section {
                LabeledSlider(title: "Sensor snapshot", value: $appState.sensorRefreshInterval, range: 0.5...5, step: 0.5,
                              format: { $0 < 1 ? "\(Int($0 * 1000)) ms" : String(format: "%.1f s", $0) })
                LabeledSlider(title: "Control loop", value: $appState.controlLoopInterval, range: 0.05...0.5, step: 0.05,
                              format: { "\(Int(($0 * 1000).rounded())) ms" })
            } header: {
                Text("Refresh")
            } footer: {
                Text("Defaults: 1 s sensor snapshot, 100 ms control loop.")
            }

            Section("General") {
                Toggle("Show temperatures in °F", isOn: $appState.useFahrenheit)
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
    }

    private var profileTakeovers: String {
        FanProfile.available
            .map { "\($0.name) \(temperature(Double($0.curve.engageTemp)))" }
            .joined(separator: ", ")
    }

    private func temperature(_ celsius: Double) -> String {
        TemperatureFormat.string(Float(celsius), fahrenheit: appState.useFahrenheit, decimals: 0)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
