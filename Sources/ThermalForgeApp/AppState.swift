//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
final class AppState: ObservableObject {
    @Published var latestStatus: ThermalStatus?
    @Published var activeProfile: FanProfile = .system
    @Published var batteryProfileID: String = UserDefaults.standard.string(forKey: "batteryProfile") ?? "default"
    @Published var adapterProfileID: String = UserDefaults.standard.string(forKey: "adapterProfile") ?? "default"
    @Published var adapterBoostEnabled: Bool = UserDefaults.standard.object(forKey: "adapterBoostEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(adapterBoostEnabled, forKey: "adapterBoostEnabled")
            refreshMonitorProfiles()
        }
    }
    @Published var usingExternalPower = false
    @Published var monitorState: MonitorState = .idle
    @Published var maxTemp: Float?
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    @Published var sensorRefreshInterval: Double = AppState.loadInterval(key: AppState.sensorRefreshIntervalKey, fallback: 1.0) {
        didSet {
            UserDefaults.standard.set(sensorRefreshInterval, forKey: Self.sensorRefreshIntervalKey)
            monitor?.updateIntervals(sensorRefreshInterval: sensorRefreshInterval,
                                     controlLoopInterval: controlLoopInterval)
        }
    }
    @Published var controlLoopInterval: Double = AppState.loadInterval(key: AppState.controlLoopIntervalKey, fallback: 0.1) {
        didSet {
            UserDefaults.standard.set(controlLoopInterval, forKey: Self.controlLoopIntervalKey)
            monitor?.updateIntervals(sensorRefreshInterval: sensorRefreshInterval,
                                     controlLoopInterval: controlLoopInterval)
        }
    }
    /// Reflects the current SMAppService login-item status so the menu toggle shows the
    /// right state. Initialized from that status as the property's DEFAULT (not reassigned
    /// in init), so `didSet` does NOT fire on launch — reading the state must never
    /// re-register. `updateLoginItem()` runs only when the user flips the toggle (the
    /// SwiftUI binding writes this), never on every launch.
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { updateLoginItem() }
    }
    /// The running daemon's version when it differs from this app's build, else
    /// nil. Non-nil drives the "update needed" banner and menu bar badge — the
    /// long-lived daemon keeps running the old binary after a `brew upgrade`
    /// until `sudo thermalforge install` re-syncs it.
    @Published var daemonVersionMismatch: String?
    /// A hold set from the CLI (`sudo thermalforge max`) that the app is
    /// reflecting rather than fighting. Non-nil suspends the app's automatic
    /// profile control and drives the "held from Terminal" banner; the user
    /// takes back over by picking a profile or pressing Default.
    @Published var externalHold: DaemonHoldState?
    /// True when the daemon has stopped answering (two consecutive missed
    /// heartbeats). Drives the "fan control unavailable" banner + Restart button:
    /// without the daemon the app can't control fans at all, so this must be
    /// visible, not just logged. Cleared the moment a heartbeat succeeds.
    @Published var daemonUnreachable: Bool = false
    /// Set when the monitor loses its required thermal sensors. Control is handed
    /// back to macOS and remains there until the user explicitly retries a profile.
    @Published var sensorFaultMessage: String?
    /// Draft value for the explicit manual fan test control.
    @Published var manualFanPercent: Double = 50
    /// Confirmed target, separate from the draft slider and the SMC manual mode
    /// (automatic profiles also use that hardware mode).
    @Published private(set) var manualAppliedPercent: Double?
    @Published private(set) var manualApplyInProgress = false
    @Published private(set) var resettingFans = false
    @Published var manualControlError: String?
    private var manualRequestID: UUID?
    private var manualAppliedAt: UInt64?
    /// Whether launchd has the ThermalForge daemon registered. Nil means the
    /// first background check has not completed yet.
    @Published var daemonInstalled: Bool?
    /// A GitHub release newer than this installed build, else nil. Non-nil drives
    /// the "Update available" banner. Set from a once-daily check and from persisted
    /// state on launch (so it shows without waiting for a network round-trip); a
    /// dismissed version is suppressed until a newer one ships.
    @Published var availableUpdate: AvailableUpdate?

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: DispatchSourceTimer?
    /// Consecutive failed heartbeats, for debouncing `daemonUnreachable`.
    private var heartbeatFailures = 0

    var canApplyManualControl: Bool {
        !manualApplyInProgress && !resettingFans && !daemonUnreachable &&
        daemonInstalled == true && externalHold == nil && sensorFaultMessage == nil &&
        monitor?.hasRecentControlTick() == true &&
        latestStatus?.hasUsableSafetyTemperature == true &&
        (latestStatus?.safetyPeakTemp ?? .infinity) < FanProfile.safetyTempThreshold &&
        latestStatus?.manualFanCommands(forPercent: manualFanPercent) != nil
    }

    static let sensorRefreshIntervalKey = "sensorRefreshInterval"
    static let controlLoopIntervalKey = "controlLoopInterval"
    static let sensorRefreshOptions: [Double] = [0.5, 1.0, 2.0, 5.0]
    static let controlLoopOptions: [Double] = [0.1, 0.25, 0.5, 1.0]

    private static func loadInterval(key: String, fallback: Double) -> Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        if key == sensorRefreshIntervalKey {
            return sensorRefreshOptions.contains(value) ? value : fallback
        }
        return controlLoopOptions.contains(value) ? value : fallback
    }

    private func profileForID(_ id: String) -> FanProfile {
        FanProfile.available.first(where: { $0.id == id }) ?? .default
    }

    private func refreshMonitorProfiles() {
        monitor?.updateProfiles(battery: profileForID(batteryProfileID),
                                adapter: profileForID(adapterProfileID),
                                batteryTransform: .identity,
                                adapterTransform: adapterBoostEnabled ? .adapterDefault : .identity)
    }

    /// Runs the 5s heartbeat/version/state polls OFF the main thread so a slow
    /// or hung daemon can never stall the UI run loop (the v0.1.7 freeze).
    private let heartbeatQueue = DispatchQueue(label: "com.thermalforge.heartbeat", qos: .utility)
    /// Off-main, serial, coalescing pump for all daemon-bound fan writes (launch
    /// adopt + monitor ramp commands). It owns its own queue, so this @MainActor
    /// class never runs socket I/O on the main actor — off-main by construction,
    /// not by relying on lax isolation. The injected executor closure runs on the
    /// pump's queue; a CLI-hold rejection is reflected back onto externalHold on the
    /// main actor.
    private lazy var commandPump: FanCommandPump = {
        let executor = self.executor   // capture the Sendable executor value (off-main use)
        return FanCommandPump { [weak self] command in
            do {
                try executor.execute(command)
                return true
            } catch {
                // Failure is NEVER silent. If a CLI hold owns the fans, this is
                // expected arbitration — reflect it on the main actor so the monitor
                // stops trying and the banner appears immediately (don't wait up to
                // 5s for the poll). Otherwise it's a real failure — log it.
                if let state = try? DaemonClient().readState(), state.isCLIHold {
                    TFLogger.shared.info("Fan command yielded to CLI hold: \(command)")
                    Task { @MainActor in self?.externalHold = state }
                } else {
                    TFLogger.shared.error("Fan command failed: \(command) — \(error)")
                    Task { @MainActor in
                        self?.monitor?.notifyCommandFailure("a fan command could not be applied")
                    }
                }
                return false
            }
        }
    }()

    init() {
        // launchAtLogin is initialized from SMAppService status as its property default
        // (above), NOT reassigned here — reassigning would fire didSet and re-register on
        // every launch. Reflecting state is a read; only a user toggle should register.

        // Show a previously-found update immediately, before any network call.
        availableUpdate = Self.storedAvailableUpdate()

        adoptDaemonStateOnLaunch()

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        // startHeartbeat() is intentionally NOT called here — it is launched from
        // adoptDaemonStateOnLaunch()'s @MainActor completion (the ordering gate),
        // so the first heartbeat poll can never land before adopt has applied the
        // launch state. The original synchronous adopt gave this ordering for free;
        // the async version must restore it explicitly.
    }

    /// Sync to whatever the daemon is actually holding at launch instead of
    /// blindly resetting (which destroyed a deliberate CLI hold and the daemon's
    /// record of it). A CLI hold is reflected and left alone; a stale supervised
    /// hold left by a crashed prior app instance is cleared here — that's the
    /// crash recovery the old reset provided, without the collateral damage.
    private func adoptDaemonStateOnLaunch() {
        let executor = self.executor
        // Read the daemon's launch state OFF the main thread so an unresponsive
        // daemon can't stall app launch — the socket read is bounded by the sendRaw
        // timeout. runAtLaunch puts this on the pump's serial queue AHEAD of any
        // ramp write, so a stale-hold reset here can never be reordered behind a
        // monitor command. During the brief pre-adopt window the monitor may still
        // issue a command; shipped arbitration rejects an app write over a CLI hold
        // and the pump latches it, so no fan state is corrupted.
        commandPump.runAtLaunch { [weak self] in
            let state = try? DaemonClient().readState()

            // Same four-way decision as before, just resolved off-main; any reset
            // runs here and only the resulting externalHold is applied on main.
            let adopted: DaemonHoldState?
            if let state, state.isCLIHold {
                // Deliberate CLI hold — reflect it, don't touch it.
                adopted = state
                TFLogger.shared.info("App launched — reflecting CLI hold: \(state.command ?? "?")")
            } else if let state, !state.isEmpty {
                // Leftover supervised hold from a crashed prior instance — this is
                // the live app now, so take over by clearing it (the crash
                // recovery the old blind reset provided).
                adopted = nil
                try? executor.execute(.resetAuto)
                TFLogger.shared.info("App launched — cleared stale app hold")
            } else if state != nil {
                adopted = nil
                TFLogger.shared.info("App launched — no active hold")
            } else {
                // State unreadable — a pre-0.1.7 daemon with no `state` verb
                // (upgrade window) or unreachable. DELIBERATE fallback to the old
                // conservative reset: without arbitration we can't tell a CLI hold
                // from a crashed prior instance's stale hold, and leaving fans
                // possibly stuck is worse than clearing a possible CLI hold.
                // Bounded to the pre-0.1.7 daemon window, where the version-
                // mismatch banner already tells the user to re-sync.
                adopted = nil
                try? executor.execute(.resetAuto)
                TFLogger.shared.info("App launched — daemon state unreadable; reset to auto (degraded)")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.externalHold = adopted
                // Restore the user's last chosen profile, but NEVER over a reflected CLI
                // hold — that hold is the most recent explicit intent and wins. With no
                // hold (including the crash-recovery branch above that just cleared a
                // stale app hold), apply the saved choice, so a crash while Default was
                // running comes back to Default. Deferred to here so the hold state is known
                // before any fan command is issued (no pre-adopt commands in the window).
                if adopted == nil {
                    let restored = self.restoredProfile()
                    self.activeProfile = restored
                    self.monitor?.switchProfile(restored)
                }
                // Ordering gate: only now that adopt has applied the launch state
                // do we start the heartbeat. This makes adopt's externalHold write
                // strictly precede the first poll's write, so a late adopt (e.g. the
                // timeout path, ~4s) can't clobber a fresher heartbeat value. It
                // also means an unbounded connect() inside adopt merely delays the
                // first heartbeat (all off the main thread) — it never stalls launch.
                self.startHeartbeat()
            }
        }
    }

    deinit {
        heartbeatTimer?.cancel()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let client = DaemonClient()
        let monitor = self.monitor
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            // Runs OFF the main thread. Each socket round-trip is bounded by the
            // request timeout, so a hung daemon can no longer stall the UI.

            // Heartbeat is NOT advisory: it refreshes the supervised hold's
            // liveness and the daemon watchdog reverts after 15s of silence. One
            // immediate retry absorbs a transient blip without waiting a full 5s
            // for the next tick.
            let loopHealthy = monitor?.hasRecentControlTick() ?? false
            if !loopHealthy {
                monitor?.suspendForEmergency("the control loop stopped responding")
            }
            let firstBeat = loopHealthy && (try? client.request(DaemonRequest(verb: .heartbeat)))?.ok == true
            let hbOK = firstBeat || (loopHealthy && ((try? client.request(DaemonRequest(verb: .heartbeat)))?.ok == true))
            let registered = ThermalForgeDaemon.isRegisteredWithLaunchd

            // Advisory: version + state. On failure/timeout DON'T assert — leave
            // the last known value untouched rather than clearing the banner on a
            // transient blip. Only a definitive read updates published state. Both
            // the `version` reply and an `unsupportedVersion` reply carry the
            // daemon's build; a reply without one is treated as an older build.
            let didReadVersion: Bool
            let versionValue: String?
            do {
                let response = try client.request(DaemonRequest(verb: .version))
                let daemonVersion = response.version ?? "an older build"
                versionValue = (daemonVersion == ThermalForgeVersion.current) ? nil : daemonVersion
                didReadVersion = true
            } catch DaemonError.incompatibleDaemon {
                // Legacy (pre-Phase-2) daemon in the upgrade window → show the
                // update-needed banner rather than leaving it stale.
                versionValue = "an older build"
                didReadVersion = true
            } catch {
                versionValue = nil
                didReadVersion = false
            }

            // Poll the daemon's hold so a CLI hold set out-of-band shows up in the
            // menu bar and suspends our monitor. Unreadable → leave externalHold
            // as-is (don't clear a reflected CLI hold on a transient failure).
            let didReadState: Bool
            let holdValue: DaemonHoldState?
            let stateReadStarted = DispatchTime.now().uptimeNanoseconds
            if let hold = try? client.readState() {
                holdValue = hold
                didReadState = true
            } else {
                holdValue = nil
                didReadState = false
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if didReadVersion { self.daemonVersionMismatch = versionValue }
                if didReadState {
                    self.externalHold = holdValue?.isCLIHold == true ? holdValue : nil
                    if let appliedAt = self.manualAppliedAt,
                       stateReadStarted >= appliedAt, holdValue?.owner != "app" {
                        // A confirmed release ends the test. Leave the monitor
                        // latched off; never resume a profile after this handback.
                        let reason = "the background service released manual fan control"
                        self.sensorFaultMessage = reason
                        self.clearManualControl()
                        monitor?.suspendForEmergency(reason)
                    }
                }
                self.daemonInstalled = registered
                if didReadState, self.externalHold == nil,
                   self.manualRequestID == nil, !self.resettingFans,
                   self.activeProfile.id != FanProfile.system.id,
                   self.sensorFaultMessage == nil {
                    monitor?.requestReapply()
                }
                // Daemon reachability — debounced so a single blip doesn't flash the
                // "fan control unavailable" banner. Two consecutive missed heartbeats
                // (~10s) is a real outage; any success clears it immediately.
                if !loopHealthy {
                    self.sensorFaultMessage = self.sensorFaultMessage ?? "the control loop stopped responding"
                    self.activeProfile = .system
                    self.clearManualControl()
                    self.heartbeatFailures = 0
                } else if hbOK {
                    self.heartbeatFailures = 0
                    self.daemonUnreachable = false
                } else {
                    self.heartbeatFailures += 1
                    if self.heartbeatFailures >= 2 { self.daemonUnreachable = true }
                }
            }

            // Ride the heartbeat as a cheap clock, but hit the network at most once a
            // day. Runs off-main; nothing here touches published state directly.
            self?.maybeCheckForUpdate()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - Update check

    // nonisolated: read from `maybeCheckForUpdate` on the heartbeat queue. Static
    // members of a @MainActor type are otherwise MainActor-isolated (a Swift 6 error
    // to touch off-main); these are immutable constants, so isolation buys nothing.
    //
    // We persist the NEXT allowed check time, not the last one, so the gate is a plain
    // `now >= nextCheck` and both the normal and backed-off cases store `now + interval`
    // — no negative-interval arithmetic to misread as a bug later.
    nonisolated private static let updateNextCheckKey = "updateNextCheck"
    nonisolated private static let updateLatestVersionKey = "updateLatestVersion"
    nonisolated private static let updateLatestURLKey = "updateLatestURL"
    nonisolated private static let updateDismissedKey = "updateDismissedVersion"
    /// Normal cadence: next check a day out. A machine asleep/off checks on next wake.
    nonisolated private static let updateCheckInterval: TimeInterval = 24 * 60 * 60
    /// After a failed check, next check ~1h out instead of a full day.
    nonisolated private static let updateRetryInterval: TimeInterval = 60 * 60

    /// Reconstruct the last-known available update from persisted state (launch path),
    /// suppressing a version the user dismissed.
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

    /// Fire a check if a day has elapsed. `nonisolated` so it runs on the heartbeat
    /// queue; only UserDefaults (thread-safe) is touched here, and the result is
    /// applied back on the main actor.
    nonisolated private func maybeCheckForUpdate() {
        let defaults = UserDefaults.standard
        let nextCheck = (defaults.object(forKey: Self.updateNextCheckKey) as? Date) ?? .distantPast
        guard Date() >= nextCheck else { return }
        // Claim the window up front so the 5s heartbeat can't refire the fetch.
        defaults.set(Date().addingTimeInterval(Self.updateCheckInterval), forKey: Self.updateNextCheckKey)

        Task { [weak self] in
            let result = await UpdateChecker.check()
            if case .failed = result {
                // Transient failure — pull the next check back to ~1h out, not a day.
                defaults.set(Date().addingTimeInterval(Self.updateRetryInterval), forKey: Self.updateNextCheckKey)
            }
            await self?.applyUpdateCheck(result)
        }
    }

    /// Apply a completed check. `.failed` is silent (prior state untouched). Only a
    /// definitive result changes what the user sees.
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
            // Honor a dismissal until a still-newer version arrives.
            if update.version != d.string(forKey: Self.updateDismissedKey) {
                availableUpdate = update
            }
        }
    }

    /// "Later" — hide the banner for this version; it returns when a newer one ships.
    func dismissUpdate() {
        if let version = availableUpdate?.version {
            UserDefaults.standard.set(version, forKey: Self.updateDismissedKey)
        }
        availableUpdate = nil
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let monitor = ThermalMonitor(
            fanControl: fc,
            profile: profileForID(batteryProfileID),
            batteryProfile: profileForID(batteryProfileID),
            adapterProfile: profileForID(adapterProfileID),
            batteryTransform: .identity,
            adapterTransform: adapterBoostEnabled ? .adapterDefault : .identity,
            sensorRefreshInterval: sensorRefreshInterval,
            controlLoopInterval: controlLoopInterval
        )
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                self?.latestStatus = status
                self?.activeProfile = profile
                self?.monitorState = state
                self?.usingExternalPower = monitor.usingExternalPower
                // Max of only the displayed sensors
                // Peak across all CPU and GPU sensors for menu bar display
                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                self?.maxTemp = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
            }
        }
        monitor.onPowerSourceUpdate = { [weak self] source in
            Task { @MainActor in
                self?.usingExternalPower = source == .external
            }
        }
        monitor.onSensorFault = { [weak self] reason in
            Task { @MainActor in
                self?.sensorFaultMessage = reason
                self?.monitorState = .idle
                self?.activeProfile = .system
                self?.clearManualControl()
            }
        }
        monitor.onFanCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't fight a CLI hold — the user set it deliberately. Decide on
                // the main actor where externalHold lives; the monitor resumes
                // control when they pick a profile or press Default.
                guard self.externalHold == nil else { return }
                // A profile tick can already be queued on the main actor when
                // Apply is clicked. Drop it while testing or releasing control.
                // The emergency reset must always be allowed through.
                if self.monitor?.isControlFaultLatched == true {
                    guard command == .resetAuto else { return }
                } else if self.manualRequestID != nil || self.resettingFans {
                    return
                }
                // Hand off to the coalescing pump; the blocking socket write happens
                // OFF the main thread. During a ramp these fire up to ~10x/sec;
                // previously each ran a blocking round-trip on the main actor and
                // starved the run loop (v0.1.7).
                self.commandPump.submit(command)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Actions

    /// Invalidate pending manual commands and release any manual or CLI hold
    /// before an explicit profile selection resumes automatic control.
    @discardableResult
    private func seizeControl() -> Bool {
        let had = externalHold != nil || manualRequestID != nil
        externalHold = nil
        clearManualControl()
        return had
    }

    private func clearManualControl() {
        manualRequestID = nil
        manualAppliedPercent = nil
        manualAppliedAt = nil
        manualApplyInProgress = false
        manualControlError = nil
    }

    func setDefault() {
        guard !resettingFans else { return }
        let took = seizeControl()
        sensorFaultMessage = nil
        if took { commandPump.submit(.resetAuto) }
        monitor?.setManualControl(false)
        batteryProfileID = FanProfile.default.id
        adapterProfileID = FanProfile.default.id
        UserDefaults.standard.set(FanProfile.default.id, forKey: "batteryProfile")
        UserDefaults.standard.set(FanProfile.default.id, forKey: "adapterProfile")
        activeProfile = .default
        monitor?.clearFaultForUserRetry()
        persistSelectedProfile(FanProfile.default.id)
        monitor?.updateProfiles(battery: .default, adapter: .default,
                                batteryTransform: .identity, adapterTransform: adapterBoostEnabled ? .adapterDefault : .identity)
        TFLogger.shared.profile("Default profile activated")
    }

    func resetAuto() {
        guard !resettingFans else { return }
        resettingFans = true
        seizeControl()
        monitor?.setManualControl(true)
        // resetAuto clears any hold (CLI or app) → daemon .none. This is the
        // no-CLI-knowledge escape from a pinned hold and returns control to macOS.
        // Send the reset off-main and reflect Apple Auto ONLY once the daemon confirms;
        // On failure the command pump enters the emergency latch.
        commandPump.submit(.resetAuto) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                self.resettingFans = false
                guard ok else {
                    TFLogger.shared.error("Reset to Apple Auto failed — daemon unreachable; fans NOT reset")
                    return
                }
                self.activeProfile = .system
                // Apple Auto is a deliberate user click, so it persists system mode — only
                // here, on the daemon-confirmed success path, never on a failed reset.
                self.persistSelectedProfile(FanProfile.system.id)
                self.monitor?.switchProfile(.system)
                TFLogger.shared.profile("Reset to Apple Auto")
            }
        }
    }

    /// Apply the slider's draft value only after an explicit button click.
    /// Automatic profile writes are paused after the click, while the monitor's
    /// sensor health checks and emergency handback continue to run.
    func applyManualFanPercent(_ percent: Double) {
        guard canApplyManualControl,
              let commands = latestStatus?.manualFanCommands(forPercent: percent) else {
            manualControlError = "Manual control is unavailable. Check the status above."
            return
        }

        let target = min(max(percent, 0), 100)
        let requestID = UUID()
        manualRequestID = requestID
        manualApplyInProgress = true
        manualAppliedAt = nil
        manualControlError = nil
        monitor?.setManualControl(true) { [weak self] in
            Task { @MainActor in
                self?.applyManualCommands(commands[...], percent: target, requestID: requestID)
            }
        }
    }

    /// Advance only after each fan accepts its target. A fault, Apple Auto, or
    /// profile selection invalidates the request before another fan can be set.
    private func applyManualCommands(_ commands: ArraySlice<FanCommand>, percent: Double, requestID: UUID) {
        guard manualRequestID == requestID,
              monitor?.isControlFaultLatched == false else { return }
        guard let command = commands.first else {
            manualAppliedPercent = percent
            manualApplyInProgress = false
            manualAppliedAt = DispatchTime.now().uptimeNanoseconds
            TFLogger.shared.profile("Manual fan test applied: \(Int(percent))%")
            return
        }
        commandPump.submit(command) { [weak self] ok in
            Task { @MainActor in
                guard let self, self.manualRequestID == requestID else { return }
                guard ok else {
                    self.clearManualControl()
                    self.manualControlError = "The manual fan command was not applied. Check the status above."
                    self.monitor?.suspendForEmergency("a manual fan command could not be applied")
                    return
                }
                self.applyManualCommands(commands.dropFirst(), percent: percent, requestID: requestID)
            }
        }
    }

    func selectProfile(_ profile: FanProfile) {
        guard !resettingFans else { return }
        let took = seizeControl()
        sensorFaultMessage = nil
        if profile.curve.handsOff || took { commandPump.submit(.resetAuto) }
        monitor?.setManualControl(false)
        batteryProfileID = profile.id
        adapterProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "batteryProfile")
        UserDefaults.standard.set(profile.id, forKey: "adapterProfile")
        activeProfile = profile
        monitor?.clearFaultForUserRetry()
        persistSelectedProfile(profile.id)
        monitor?.updateProfiles(battery: profile, adapter: profile,
                                batteryTransform: .identity, adapterTransform: adapterBoostEnabled ? .adapterDefault : .identity)
        TFLogger.shared.profile("Selected: \(profile.name)")
    }

    func selectBatteryProfile(_ profile: FanProfile) {
        guard !resettingFans else { return }
        if seizeControl() { commandPump.submit(.resetAuto) }
        sensorFaultMessage = nil
        monitor?.setManualControl(false)
        monitor?.clearFaultForUserRetry()
        batteryProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "batteryProfile")
        persistSelectedProfile(profile.id)
        monitor?.updateProfiles(battery: profile, adapter: profileForID(adapterProfileID),
                                batteryTransform: .identity, adapterTransform: adapterBoostEnabled ? .adapterDefault : .identity)
    }

    func selectAdapterProfile(_ profile: FanProfile) {
        guard !resettingFans else { return }
        if seizeControl() { commandPump.submit(.resetAuto) }
        sensorFaultMessage = nil
        monitor?.setManualControl(false)
        monitor?.clearFaultForUserRetry()
        adapterProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "adapterProfile")
        monitor?.updateProfiles(battery: profileForID(batteryProfileID), adapter: profile,
                                batteryTransform: .identity, adapterTransform: adapterBoostEnabled ? .adapterDefault : .identity)
    }

    // MARK: - Profile persistence

    /// The user's last explicitly-chosen profile id, so the app reopens to it instead of
    /// always Default. Written ONLY on a user click (picker, Default) via
    /// `persistSelectedProfile`, never on the monitor's per-tick echo of `activeProfile`
    /// or on watchdog / thermal-floor / crash-recovery fan resets.
    private static let selectedProfileKey = "selectedProfile"

    private func persistSelectedProfile(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.selectedProfileKey)
    }

    /// The profile to restore at launch: the persisted choice resolved against the known
    /// profiles, or Default when nothing is saved or the id no longer exists.
    private func restoredProfile() -> FanProfile {
        FanProfile.selectable(id: UserDefaults.standard.string(forKey: Self.selectedProfileKey))
    }

    // MARK: - Daemon recovery

    /// Force the root daemon to restart via launchd, from the "Restart daemon"
    /// button on the unreachable banner. Runs OFF the main thread (it blocks on the
    /// macOS auth dialog). Uses `launchctl kickstart -k` — the standard "restart
    /// this service" — via an Authorization prompt: macOS shows the password dialog
    /// and handles the credential; the app never sees it. On success the next
    /// heartbeat clears `daemonUnreachable`.
    func restartDaemon() {
        let label = ThermalForgeDaemon.label
        DispatchQueue.global(qos: .userInitiated).async {
            // Escaped for AppleScript's `do shell script`; the label is a fixed
            // constant (no user input), so there's nothing untrusted to inject.
            let script = "do shell script \"/bin/launchctl kickstart -k system/\(label)\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    TFLogger.shared.info("Restart daemon: launchctl kickstart requested")
                } else {
                    // Non-zero includes the user cancelling the auth prompt (-128).
                    TFLogger.shared.error("Restart daemon failed (osascript exit \(p.terminationStatus))")
                }
            } catch {
                TFLogger.shared.error("Restart daemon failed to launch: \(error)")
            }
        }
    }

    /// Install the bundled CLI as the privileged launchd daemon. Authentication
    /// is handled by macOS; the app never receives or stores the password.
    func installDaemon() {
        guard let cli = daemonCLIPath() else {
            TFLogger.shared.error("Daemon install unavailable — no bundled or installed CLI found")
            return
        }
        let command = "\(shellQuote(cli)) install"
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
                    TFLogger.shared.info("Daemon install requested")
                } else {
                    TFLogger.shared.error("Daemon install failed (osascript exit \(p.terminationStatus))")
                }
            } catch {
                TFLogger.shared.error("Daemon install failed to launch: \(error)")
            }
        }
    }

    private func daemonCLIPath() -> String? {
        let candidates = [
            Bundle.main.url(forResource: "thermalforge", withExtension: nil)?.path,
            "/usr/local/bin/thermalforge",
            "/opt/homebrew/bin/thermalforge",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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
            launchAtLogin = !launchAtLogin // revert toggle
        }
    }
}
