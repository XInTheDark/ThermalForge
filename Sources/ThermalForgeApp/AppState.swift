//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between the control loop and SwiftUI: settings, the
//  latest monitor snapshot, daemon health, and user actions.
//
//  Control never latches off. A failed fan command is retried by the
//  actuator; lost sensors hand the fans to Apple Auto until readings return;
//  a stalled loop stops heartbeats so the daemon watchdog returns the fans to
//  Apple Auto, and control resumes when the loop does.
//

import AppKit
import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
final class AppState: ObservableObject {
    // MARK: Settings (persisted)

    @Published var batteryProfileID: String = AppState.storedProfileID(Keys.batteryProfile)
    @Published var adapterProfileID: String = AppState.storedProfileID(Keys.adapterProfile)
    /// Apple Auto selected: ThermalForge leaves the fans to macOS.
    @Published private(set) var appleAutoSelected: Bool =
        UserDefaults.standard.string(forKey: Keys.selectedProfile) == FanProfile.system.id
    @Published var adapterBoostEnabled: Bool = AppState.storedBool(Keys.adapterBoost, default: true) {
        didSet { UserDefaults.standard.set(adapterBoostEnabled, forKey: Keys.adapterBoost); pushSettings() }
    }
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: Keys.fahrenheit) {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: Keys.fahrenheit) }
    }
    @Published var sensorRefreshInterval: Double = AppState.storedDouble(Keys.sensorInterval, default: 1.0, in: 0.5...5.0) {
        didSet {
            UserDefaults.standard.set(sensorRefreshInterval, forKey: Keys.sensorInterval)
            monitor?.updateIntervals(sensorRefreshInterval: sensorRefreshInterval, controlLoopInterval: controlLoopInterval)
        }
    }
    @Published var controlLoopInterval: Double = AppState.storedDouble(Keys.controlInterval, default: 0.1, in: 0.05...0.5) {
        didSet {
            UserDefaults.standard.set(controlLoopInterval, forKey: Keys.controlInterval)
            monitor?.updateIntervals(sensorRefreshInterval: sensorRefreshInterval, controlLoopInterval: controlLoopInterval)
        }
    }
    @Published var smoothingEnabled: Bool = AppState.storedBool(Keys.smoothing, default: true) {
        didSet { UserDefaults.standard.set(smoothingEnabled, forKey: Keys.smoothing); pushSettings() }
    }
    @Published var smoothingAttackSeconds: Double = AppState.storedDouble(
        Keys.attack, default: TemperatureFilter.defaultAttackSeconds, in: 1...15) {
        didSet { UserDefaults.standard.set(smoothingAttackSeconds, forKey: Keys.attack); pushSettings() }
    }
    @Published var smoothingDecaySeconds: Double = AppState.storedDouble(
        Keys.decay, default: TemperatureFilter.defaultDecaySeconds, in: 5...60) {
        didSet { UserDefaults.standard.set(smoothingDecaySeconds, forKey: Keys.decay); pushSettings() }
    }
    @Published var safetyLimitTemp: Double = AppState.storedDouble(
        Keys.safetyLimit, default: Double(FanProfile.safetyTempThreshold),
        in: Double(FanProfile.safetyLimitRange.lowerBound)...Double(FanProfile.safetyLimitRange.upperBound)) {
        didSet {
            UserDefaults.standard.set(safetyLimitTemp, forKey: Keys.safetyLimit)
            pushSettings()
            let limit = Float(safetyLimitTemp)
            let executor = self.executor
            commandQueue.async { try? executor.execute(.setSafetyLimit(limit)) }
        }
    }
    /// Hand the fans back to Apple Auto (which can stop them) when cool.
    @Published var handBackWhenCool: Bool = AppState.storedBool(Keys.handBack, default: true) {
        didSet { UserDefaults.standard.set(handBackWhenCool, forKey: Keys.handBack); pushSettings() }
    }
    /// Use `customTakeoverTemp` instead of each profile's own takeover temperature.
    @Published var customTakeoverEnabled: Bool = AppState.storedBool(Keys.customTakeover, default: false) {
        didSet { UserDefaults.standard.set(customTakeoverEnabled, forKey: Keys.customTakeover); pushSettings() }
    }
    @Published var customTakeoverTemp: Double = AppState.storedDouble(Keys.takeoverTemp, default: 70, in: 50...90) {
        didSet { UserDefaults.standard.set(customTakeoverTemp, forKey: Keys.takeoverTemp); pushSettings() }
    }
    /// Reflects the SMAppService login-item status. Initialized as the property
    /// default so `didSet` only runs when the user flips the toggle.
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { updateLoginItem() }
    }

    // MARK: Runtime state

    @Published private(set) var snapshot: MonitorSnapshot?
    /// Running daemon version when it differs from this app's build.
    @Published private(set) var daemonVersionMismatch: String?
    /// A hold set from the CLI (`sudo thermalforge max`) that the app reflects
    /// instead of fighting. Picking a profile or Apple Auto takes over.
    @Published private(set) var externalHold: DaemonHoldState?
    /// Two consecutive missed heartbeats.
    @Published private(set) var daemonUnreachable = false
    /// Nil until the first background check completes.
    @Published private(set) var daemonInstalled: Bool?
    @Published private(set) var commandHealth: FanActuator.Health = .ok
    /// The control loop stopped ticking; the daemon watchdog returns the fans to
    /// Apple Auto. Cleared as soon as the loop runs again.
    @Published private(set) var loopStalled = false
    /// Another fan-control app that is running and will fight ThermalForge.
    @Published private(set) var competingFanApp: String?
    /// The manual fan level being held (0…100), or nil when following a profile.
    @Published private(set) var manualPercent: Double?
    @Published var manualDraftPercent: Double = 50
    @Published var availableUpdate: AvailableUpdate?

    private var monitor: ThermalMonitor?
    private var actuator: FanActuator?
    private let executor = PrivilegedExecutor()
    /// Off-main queue for one-off daemon calls (reset, safety limit, takeover).
    private let commandQueue = DispatchQueue(label: "com.thermalforge.app-commands", qos: .userInitiated)
    private let heartbeatQueue = DispatchQueue(label: "com.thermalforge.heartbeat", qos: .utility)
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatFailures = 0
    private var lastSafetyAlert: Date?
    private var wakeObserver: NSObjectProtocol?

    enum Keys {
        static let batteryProfile = "batteryProfile"
        static let adapterProfile = "adapterProfile"
        static let selectedProfile = "selectedProfile"
        static let adapterBoost = "adapterBoostEnabled"
        static let fahrenheit = "useFahrenheit"
        static let sensorInterval = "sensorRefreshInterval"
        static let controlInterval = "controlLoopInterval"
        static let smoothing = "temperatureSmoothingEnabled"
        static let attack = "smoothingAttackSeconds"
        static let decay = "smoothingDecaySeconds"
        static let safetyLimit = "safetyLimitTemperature"
        static let handBack = "lowTempRegimeEnabled"
        static let customTakeover = "customTakeoverEnabled"
        static let takeoverTemp = "customTakeoverTemperature"
    }

    init() {
        availableUpdate = Self.storedAvailableUpdate()
        ThermalLogger.cleanExpired()
        startMonitoring()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                TFLogger.shared.info("Woke from sleep — resynchronizing fan control")
                self?.monitor?.resync(resetHistory: true)
            }
        }
    }

    deinit {
        heartbeatTimer?.cancel()
    }

    // MARK: - Derived state

    var batteryProfile: FanProfile { FanProfile.selectable(id: batteryProfileID) }
    var adapterProfile: FanProfile { FanProfile.selectable(id: adapterProfileID) }
    var usingExternalPower: Bool { snapshot?.externalPower ?? false }

    /// The profile that applies on the current power source (ignoring Apple Auto).
    var currentProfile: FanProfile { usingExternalPower ? adapterProfile : batteryProfile }

    var controlSettings: ControlSettings {
        ControlSettings(
            handBackWhenCool: handBackWhenCool,
            takeoverTemp: customTakeoverEnabled ? Float(customTakeoverTemp) : nil,
            safetyLimit: Float(safetyLimitTemp),
            batteryTransform: .identity,
            adapterTransform: adapterBoostEnabled ? .adapterDefault : .identity,
            filter: TemperatureFilter(isEnabled: smoothingEnabled,
                                      attackSeconds: smoothingAttackSeconds,
                                      decaySeconds: smoothingDecaySeconds)
        )
    }

    /// Temperature shown in the menu bar: the control temperature.
    var menuTemperature: Float? {
        guard let snapshot else { return nil }
        return smoothingEnabled ? snapshot.controlTemp : snapshot.status.nominalPeakTemp
    }

    var canApplyManual: Bool {
        daemonInstalled == true && !daemonUnreachable && externalHold == nil
            && snapshot?.sensorIssue == nil && snapshot?.status.perFanTarget(level: 0.5) != nil
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard let fanControl = try? FanControl() else {
            TFLogger.shared.error("Could not open the SMC — fan control unavailable")
            return
        }

        let executor = self.executor
        let actuator = FanActuator { [weak self] target in
            do {
                try executor.apply(target)
            } catch DaemonError.rejected(.heldByCLI, _) {
                // A Terminal hold owns the fans: reflect it rather than fight it.
                let state = try? executor.readState()
                Task { @MainActor in self?.reflectExternalHold(state) }
                throw DaemonError.rejected(.heldByCLI, "fans are held from Terminal")
            } catch DaemonError.rejected(.safetyLocked, _) {
                // A max-fan latch left by a pre-0.3 app build: clear it, then retry.
                try executor.execute(.resetAuto)
                try executor.apply(target)
            }
        }
        actuator.onHealthChange = { [weak self] health in
            Task { @MainActor in self?.commandHealth = health }
        }
        actuator.onAttempt = { target, error in
            if let error { TFLogger.shared.error("Fan command for \(target) failed: \(error)") }
        }

        let monitor = ThermalMonitor(
            source: fanControl,
            actuator: actuator,
            batteryProfile: batteryProfile,
            adapterProfile: adapterProfile,
            appleAuto: appleAutoSelected,
            settings: controlSettings,
            sensorRefreshInterval: sensorRefreshInterval,
            controlLoopInterval: controlLoopInterval
        )
        monitor.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.receive(snapshot) }
        }
        // Send nothing until the daemon's current hold is known.
        monitor.setMode(.paused)
        monitor.start()
        self.monitor = monitor
        self.actuator = actuator

        adoptDaemonStateOnLaunch()
    }

    private func receive(_ snapshot: MonitorSnapshot) {
        let wasOverride = self.snapshot?.safetyOverride ?? false
        self.snapshot = snapshot
        if snapshot.safetyOverride, !wasOverride {
            // One alert per episode, at most every ten minutes.
            if lastSafetyAlert.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                lastSafetyAlert = Date()
                NotificationManager.shared.sendSafetyAlert(sensorTemp: snapshot.status.safetyPeakTemp,
                                                           limitTemp: Float(safetyLimitTemp))
            }
        }
    }

    private func pushSettings() {
        monitor?.updateSettings(controlSettings)
    }

    private func pushProfiles() {
        monitor?.updateProfiles(battery: batteryProfile, adapter: adapterProfile, appleAuto: appleAutoSelected)
    }

    /// Sync with whatever the daemon holds at launch. A Terminal hold is
    /// reflected and left alone; anything else is replaced by the active profile.
    private func adoptDaemonStateOnLaunch() {
        let executor = self.executor
        let limit = Float(safetyLimitTemp)
        commandQueue.async { [weak self] in
            let state = try? executor.readState()
            if state?.safetyLatched == true, state?.isCLIHold != true {
                // Pre-0.3 builds latched fans at max after a hotspot spike. The new
                // safety override is self-clearing, so release the latch.
                try? executor.execute(.resetAuto)
                TFLogger.shared.info("App launched — released a max-fan safety latch from an older build")
            }
            try? executor.execute(.setSafetyLimit(limit))
            Task { @MainActor in
                guard let self else { return }
                if let state, state.isCLIHold {
                    TFLogger.shared.info("App launched — reflecting Terminal hold: \(state.command ?? "?")")
                    self.reflectExternalHold(state)
                } else {
                    self.monitor?.setMode(.automatic)
                }
                self.startHeartbeat()
            }
        }
    }

    private func reflectExternalHold(_ state: DaemonHoldState?) {
        guard let state, state.isCLIHold else { return }
        externalHold = state
        manualPercent = nil
        monitor?.setMode(.paused)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let client = DaemonClient()
        let monitor = self.monitor
        let actuator = self.actuator
        // Used only on heartbeatQueue (serial), as DaemonBinaryCheck requires.
        let binaryCheck = Self.bundledCLIPath.map { DaemonBinaryCheck(bundledPath: $0) }
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 1, repeating: 5)
        timer.setEventHandler { [weak self] in
            // Off the main thread; every socket call is bounded by a timeout.
            // A heartbeat proves the control loop is alive. When it is not, stay
            // silent so the daemon watchdog hands the fans to Apple Auto.
            let loopHealthy = monitor?.hasRecentTick() ?? false
            let limit = Float(Self.storedDouble(Keys.safetyLimit, default: Double(FanProfile.safetyTempThreshold),
                                                in: Double(FanProfile.safetyLimitRange.lowerBound)...Double(FanProfile.safetyLimitRange.upperBound)))
            let heartbeat = DaemonRequest(verb: .heartbeat, safetyLimitTemp: limit)
            var hbOK = false
            if loopHealthy {
                hbOK = (try? client.request(heartbeat))?.ok == true
                    || (try? client.request(heartbeat))?.ok == true
            }
            let reachable = hbOK || ThermalForgeDaemon.isRunning
            let registered = reachable ? true : ThermalForgeDaemon.isRegisteredWithLaunchd

            var versionValue: String??   // nil = unknown, .some(nil) = matches
            do {
                let response = try client.request(DaemonRequest(verb: .version))
                let daemonVersion = response.version ?? "an older build"
                if daemonVersion != ThermalForgeVersion.current {
                    versionValue = .some(daemonVersion)
                } else if binaryCheck?.installedDiffers() == true {
                    versionValue = .some("a different local build")
                } else {
                    versionValue = .some(nil)
                }
            } catch DaemonError.incompatibleDaemon {
                versionValue = .some("an older build")
            } catch {
                versionValue = nil
            }

            let hold = try? client.readState()
            if let hold, hold.safetyLatched, !hold.isCLIHold {
                // Latch from an older app build (or one reinstalled mid-episode).
                _ = try? client.execute(.resetAuto)
                actuator?.invalidate()
            } else if let hold, hold.isEmpty, let confirmed = actuator?.confirmedTarget, confirmed != .system {
                // The daemon lost our hold (restart or watchdog): send it again.
                TFLogger.shared.info("Daemon no longer holds \(confirmed) — resending")
                monitor?.resync(resetHistory: false)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loopStalled = !loopHealthy
                self.updateCompetingFanApp()
                if let versionValue { self.daemonVersionMismatch = versionValue }
                self.daemonInstalled = registered
                if let hold {
                    if hold.isCLIHold {
                        if self.externalHold != hold { self.reflectExternalHold(hold) }
                    } else if self.externalHold != nil {
                        // The Terminal hold ended (e.g. `thermalforge auto`).
                        self.externalHold = nil
                        self.monitor?.setMode(self.manualPercent.map { .manual(level: Float($0 / 100)) } ?? .automatic)
                    }
                }
                if reachable {
                    self.heartbeatFailures = 0
                    self.daemonUnreachable = false
                } else {
                    self.heartbeatFailures += 1
                    if self.heartbeatFailures >= 2 { self.daemonUnreachable = true }
                }
            }

            self?.maybeCheckForUpdate()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    /// Fan controllers known to write SMC fan targets. Two controllers fight:
    /// each overwrites the other's target and the fans hunt.
    private static let competingFanApps: [(bundleID: String, name: String)] = [
        ("com.tunabellysoftware.tgpro", "TG Pro"),
        ("com.crystalidea.macsfancontrol", "Macs Fan Control"),
    ]

    private func updateCompetingFanApp() {
        let running = NSWorkspace.shared.runningApplications
        let found = Self.competingFanApps.first { app in
            running.contains { $0.bundleIdentifier == app.bundleID || $0.localizedName == app.name }
        }?.name
        if found != competingFanApp, let found {
            TFLogger.shared.info("\(found) is running — it also controls the fans")
        }
        competingFanApp = found
    }

    // MARK: - Actions

    func selectBatteryProfile(_ profile: FanProfile) {
        batteryProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: Keys.batteryProfile)
        resumeProfiles()
    }

    func selectAdapterProfile(_ profile: FanProfile) {
        adapterProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: Keys.adapterProfile)
        resumeProfiles()
    }

    /// Use one profile on both power sources.
    func selectProfile(_ profile: FanProfile) {
        batteryProfileID = profile.id
        adapterProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: Keys.batteryProfile)
        UserDefaults.standard.set(profile.id, forKey: Keys.adapterProfile)
        resumeProfiles()
    }

    /// Follow the selected profiles (leaving Apple Auto or a manual hold).
    func resumeProfiles() {
        appleAutoSelected = false
        UserDefaults.standard.set(currentProfile.id, forKey: Keys.selectedProfile)
        manualPercent = nil
        pushProfiles()
        takeOver(mode: .automatic)
        TFLogger.shared.profile("Profiles: battery \(batteryProfile.name), adapter \(adapterProfile.name)")
    }

    func selectAppleAuto() {
        appleAutoSelected = true
        UserDefaults.standard.set(FanProfile.system.id, forKey: Keys.selectedProfile)
        manualPercent = nil
        pushProfiles()
        takeOver(mode: .automatic)
        TFLogger.shared.profile("Apple Auto selected")
    }

    /// Hold every fan at `percent` of its range until the user resumes a profile.
    /// The hotspot safety override still applies.
    func applyManual(_ percent: Double) {
        guard canApplyManual || externalHold != nil else { return }
        let value = min(max(percent.rounded(), 0), 100)
        manualPercent = value
        takeOver(mode: .manual(level: Float(value / 100)))
        TFLogger.shared.profile("Manual fan level: \(Int(value))%")
    }

    /// Release a Terminal hold if there is one, then switch the monitor mode.
    /// The daemon refuses app commands over a Terminal hold, so it is cleared first.
    private func takeOver(mode: MonitorMode) {
        guard externalHold != nil else {
            monitor?.setMode(mode)
            return
        }
        externalHold = nil
        let executor = self.executor
        commandQueue.async { [weak self] in
            try? executor.execute(.resetAuto)
            Task { @MainActor in self?.monitor?.setMode(mode) }
        }
    }

    // MARK: - Profile persistence helpers

    private static func storedProfileID(_ key: String) -> String {
        FanProfile.selectable(id: UserDefaults.standard.string(forKey: key)).id
    }

    nonisolated private static func storedDouble(_ key: String, default value: Double, in range: ClosedRange<Double>) -> Double {
        let stored = UserDefaults.standard.object(forKey: key) as? Double ?? value
        guard stored.isFinite else { return value }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private static func storedBool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    // MARK: - Update check

    // We persist the NEXT allowed check time, so the gate is `now >= nextCheck`.
    nonisolated private static let updateNextCheckKey = "updateNextCheck"
    nonisolated private static let updateLatestVersionKey = "updateLatestVersion"
    nonisolated private static let updateLatestURLKey = "updateLatestURL"
    nonisolated private static let updateDismissedKey = "updateDismissedVersion"
    nonisolated private static let updateCheckInterval: TimeInterval = 24 * 60 * 60
    nonisolated private static let updateRetryInterval: TimeInterval = 60 * 60

    private static func storedAvailableUpdate() -> AvailableUpdate? {
        let d = UserDefaults.standard
        guard let version = d.string(forKey: updateLatestVersionKey),
              version != d.string(forKey: updateDismissedKey) else { return nil }
        return UpdateChecker.evaluate(
            current: ThermalForgeVersion.current,
            tagName: version,
            url: d.string(forKey: updateLatestURLKey) ?? UpdateChecker.releasesPageURL
        )
    }

    /// Fire a check if a day has elapsed. Runs on the heartbeat queue.
    nonisolated private func maybeCheckForUpdate() {
        let defaults = UserDefaults.standard
        let nextCheck = (defaults.object(forKey: Self.updateNextCheckKey) as? Date) ?? .distantPast
        guard Date() >= nextCheck else { return }
        defaults.set(Date().addingTimeInterval(Self.updateCheckInterval), forKey: Self.updateNextCheckKey)

        Task { [weak self] in
            let result = await UpdateChecker.check()
            if case .failed = result {
                defaults.set(Date().addingTimeInterval(Self.updateRetryInterval), forKey: Self.updateNextCheckKey)
            }
            await self?.applyUpdateCheck(result)
        }
    }

    func applyUpdateCheck(_ result: UpdateCheckResult) {
        let d = UserDefaults.standard
        switch result {
        case .failed:
            return
        case .upToDate:
            d.removeObject(forKey: Self.updateLatestVersionKey)
            d.removeObject(forKey: Self.updateLatestURLKey)
            availableUpdate = nil
        case .update(let update):
            d.set(update.version, forKey: Self.updateLatestVersionKey)
            d.set(update.url, forKey: Self.updateLatestURLKey)
            if update.version != d.string(forKey: Self.updateDismissedKey) {
                availableUpdate = update
            }
        }
    }

    func dismissUpdate() {
        if let version = availableUpdate?.version {
            UserDefaults.standard.set(version, forKey: Self.updateDismissedKey)
        }
        availableUpdate = nil
    }

    // MARK: - Daemon recovery

    /// Restart the root daemon via launchd (`launchctl kickstart -k`) behind a
    /// macOS administrator prompt. Off the main thread.
    func restartDaemon() {
        runPrivileged("/bin/launchctl kickstart -k system/\(ThermalForgeDaemon.label)", purpose: "Restart daemon")
    }

    /// Install the bundled CLI as the privileged launchd daemon.
    func installDaemon() {
        guard let cli = daemonCLIPath() else {
            TFLogger.shared.error("Daemon install unavailable — no bundled or installed CLI found")
            return
        }
        runPrivileged("\(shellQuote(cli)) install", purpose: "Daemon install") { [weak self] in
            self?.monitor?.resync(resetHistory: false)
        }
    }

    private func runPrivileged(_ command: String, purpose: String, onSuccess: (@MainActor () -> Void)? = nil) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    TFLogger.shared.info("\(purpose) succeeded")
                    if let onSuccess { Task { @MainActor in onSuccess() } }
                } else {
                    // Non-zero includes the user cancelling the prompt (-128).
                    TFLogger.shared.error("\(purpose) failed (osascript exit \(p.terminationStatus))")
                }
            } catch {
                TFLogger.shared.error("\(purpose) failed to launch: \(error)")
            }
        }
    }

    /// The CLI shipped inside the app bundle, if this build includes one.
    nonisolated static var bundledCLIPath: String? {
        Bundle.main.url(forResource: "thermalforge", withExtension: nil)?.path
    }

    private func daemonCLIPath() -> String? {
        [Self.bundledCLIPath, "/usr/local/bin/thermalforge", "/opt/homebrew/bin/thermalforge"]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            TFLogger.shared.error("Launch at login toggle failed: \(error)")
            launchAtLogin = !launchAtLogin
        }
    }
}
