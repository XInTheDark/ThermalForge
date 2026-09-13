//
//  FanControl.swift
//  ThermalForge
//
//  Core fan control operations: unlock, set speed, reset, status, discover.
//

import Foundation

// MARK: - Types

public enum ThermalForgeError: Error, CustomStringConvertible {
    case smcConnectionFailed
    case unlockFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case rpmOutOfRange(requested: Float, min: Float, max: Float)
    case invalidFan(index: Int)

    public var description: String {
        switch self {
        case .smcConnectionFailed:
            return "Failed to connect to AppleSMC. Is this a Mac with SMC?"
        case .unlockFailed(let detail):
            return "Fan unlock failed: \(detail)"
        case .readFailed(let key):
            return "Failed to read SMC key: \(key)"
        case .writeFailed(let key):
            return "Failed to write SMC key: \(key). Run with sudo."
        case .rpmOutOfRange(let req, let min, let max):
            return "RPM \(Int(req)) is out of range [\(Int(min))–\(Int(max))]"
        case .invalidFan(let index):
            return "Invalid fan index: \(index)"
        }
    }
}

public struct FanInfo {
    public let index: Int
    public let actualRPM: Float
    public let targetRPM: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let mode: String
}

public struct ThermalStatus: Encodable {
    public let fans: [FanStatus]
    public let temperatures: [String: Float]

    public struct FanStatus: Encodable {
        public let index: Int
        public let actualRPM: Int
        public let targetRPM: Int
        public let minRPM: Int
        public let maxRPM: Int
        public let mode: String
    }
}

extension ThermalStatus {
    /// Each fan uses its own hardware range. Zero means minimum RPM, not off.
    public func manualFanCommands(forPercent percent: Double) -> [FanCommand]? {
        guard percent.isFinite, !fans.isEmpty,
              fans.allSatisfy(\.hasUsableRPMLimits) else { return nil }
        let fraction = min(max(percent, 0), 100) / 100
        return fans.map { fan in
            let rpm = Double(fan.minRPM) + (Double(fan.maxRPM) - Double(fan.minRPM)) * fraction
            return .setFan(index: fan.index, rpm: Float(rpm.rounded()))
        }
    }

    public var hasUsableSafetyTemperature: Bool {
        temperatures.keys.contains { key in
            ["TC", "Tp", "Te", "Tf", "TG", "Tg"].contains { key.hasPrefix($0) }
        }
    }

    /// Peak of the CPU core diodes (matching Stats' "Hottest CPU").
    /// Uses nominal core diodes across M1-M5 and Intel. Falls back to
    /// non-hotspot CPU sensors if specific core keys aren't matched.
    public var cpuCoreMaxTemp: Float? {
        let coreTemps = temperatures.filter { key, _ in
            FanControl.cpuCoreKeys.contains(key)
        }.values
        if let max = coreTemps.max() { return max }
        let nonHotspot = temperatures.filter { key, _ in
            ["TC", "Tp", "Te", "Tf"].contains { key.hasPrefix($0) } && !FanControl.hotspotKeys.contains(key)
        }.values
        return nonHotspot.max() ?? temperatures.filter { key, _ in
            ["TC", "Tp", "Te", "Tf"].contains { key.hasPrefix($0) }
        }.values.max()
    }

    /// Peak of the GPU core diodes (matching Stats' "Hottest GPU").
    public var gpuCoreMaxTemp: Float? {
        let coreTemps = temperatures.filter { key, _ in
            FanControl.gpuCoreKeys.contains(key)
        }.values
        if let max = coreTemps.max() { return max }
        return temperatures.filter { key, _ in
            ["TG", "Tg"].contains { key.hasPrefix($0) }
        }.values.max()
    }

    /// Nominal peak temperature (max of CPU core max and GPU core max).
    /// Used for steady-state fan profile curves and nominal UI display,
    /// reflecting sustained compute load rather than transient hotspot spikes.
    public var nominalPeakTemp: Float {
        let cpu = cpuCoreMaxTemp ?? 0
        let gpu = gpuCoreMaxTemp ?? 0
        let peak = max(cpu, gpu)
        return peak > 0 ? peak : safetyPeakTemp
    }

    /// Peak silicon hotspot temperature across CPU, GPU, and SoC junction sensors.
    public var siliconHotspotTemp: Float {
        let hotspotTemps = temperatures.filter { key, _ in
            FanControl.hotspotKeys.contains(key)
        }.values
        return hotspotTemps.max() ?? safetyPeakTemp
    }

    /// Peak of the CPU (`TC`/`Tp`/`Te`/`Tf`) and GPU (`TG`/`Tg`) sensors including hotspots —
    /// the temperature the thermal safety floor watches.
    public var safetyPeakTemp: Float {
        func peak(_ prefixes: [String]) -> Float {
            temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
                .values.max() ?? 0
        }
        return max(peak(["TC", "Tp", "Te", "Tf"]), peak(["TG", "Tg"]))
    }
}

extension ThermalStatus.FanStatus {
    public var hasUsableRPMLimits: Bool {
        (0...9).contains(index) && minRPM >= 0 && maxRPM > minRPM
    }

    /// Actual speed in the same minimum-to-maximum range used by manual control.
    public var actualPercent: Int? {
        guard hasUsableRPMLimits, actualRPM >= 0 else { return nil }
        let fraction = (Double(actualRPM) - Double(minRPM)) / (Double(maxRPM) - Double(minRPM))
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}

public struct DiscoveredKey {
    public let key: String
    public let size: UInt32
    public let type: String
    public let bytes: [UInt8]
}

// MARK: - Fan Control

public protocol ThermalStatusSource {
    func status() throws -> ThermalStatus
}

public final class FanControl: ThermalStatusSource {
    private let smc: SMCConnection
    /// Which mode key works on this hardware (detected at init)
    private let modeKeyTemplate: String
    /// Whether Ftst unlock is available (M1-M4) or not (M5+)
    private let hasFtst: Bool
    /// Thermal keys present on this machine. SMC key availability is stable for
    /// the lifetime of a boot, so probe the candidate list once instead of
    /// repeatedly asking the SMC about absent keys on every status read.
    private let supportedThermalKeys: [String]
    private let supportedSafetyTemperatureKeys: [String]

    public init() throws {
        guard let connection = SMCConnection() else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.smc = connection

        // Detect hardware: which mode key exists?
        // M5 Max uses F%dmd (lowercase), M1-M4 use F%dMd (uppercase)
        let lowerResult = smc.readKey(SMCFanKey.key(SMCFanKey.modeLower, fan: 0))
        if lowerResult.success {
            self.modeKeyTemplate = SMCFanKey.modeLower
        } else {
            self.modeKeyTemplate = SMCFanKey.modeUpper
        }

        // Check if Ftst exists (M1-M4 unlock mechanism)
        if let info = smc.getKeyInfo(SMCFanKey.forceTest), info.size > 0 {
            self.hasFtst = true
        } else {
            self.hasFtst = false
        }

        let candidateThermalKeys = FanControl.thermalKeys
        let connectionForProbe = connection
        let supported = candidateThermalKeys.filter { connectionForProbe.getKeyInfo($0) != nil }
        self.supportedThermalKeys = supported
        self.supportedSafetyTemperatureKeys = supported.filter { key in
            ["TC", "Tp", "Te", "Tf", "TG", "Tg", "TP"].contains { key.hasPrefix($0) }
        }
    }

    // MARK: - Fan Count

    public func fanCount() throws -> Int {
        let result = smc.readKey(SMCFanKey.count)
        guard result.success, !result.bytes.isEmpty else {
            throw ThermalForgeError.readFailed(SMCFanKey.count)
        }
        let count = Int(result.bytes[0])
        guard (1...10).contains(count) else {
            throw ThermalForgeError.readFailed("\(SMCFanKey.count) returned invalid fan count \(count)")
        }
        return count
    }

    // MARK: - Read Fan Info

    public func fanInfo(_ index: Int) throws -> FanInfo {
        // SMC fan keys are exactly four characters (F0Ac … F9Ac). Validate the
        // index before formatting so malformed CLI input becomes an error rather
        // than tripping SMCConnection's key-length precondition.
        guard (0...9).contains(index) else {
            throw ThermalForgeError.invalidFan(index: index)
        }
        let actual = readFanFloat(index, template: SMCFanKey.actual)
        let target = readFanFloat(index, template: SMCFanKey.target)
        let minimum = readFanFloat(index, template: SMCFanKey.minimum)
        let maximum = readFanFloat(index, template: SMCFanKey.maximum)

        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let modeResult = smc.readKey(modeKey)
        let modeValue = modeResult.success && !modeResult.bytes.isEmpty ? modeResult.bytes[0] : 0
        let mode: String
        switch modeValue {
        case 0: mode = "auto"
        case 1: mode = "manual"
        case 3: mode = "system"
        default: mode = "unknown(\(modeValue))"
        }

        return FanInfo(
            index: index,
            actualRPM: actual,
            targetRPM: target,
            minRPM: minimum,
            maxRPM: maximum,
            mode: mode
        )
    }

    // MARK: - Unlock

    /// Unlock fans for manual control.
    /// On M1-M4: writes Ftst=1, then polls until mode write succeeds.
    /// On M5+: Ftst doesn't exist, attempts direct mode write.
    private func unlockFans(count: Int) throws {
        if hasFtst {
            // M1-M4 path: Ftst unlock suppresses thermalmonitord
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw ThermalForgeError.unlockFailed(
                    "Failed to write Ftst=1. Run with sudo."
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Set each fan to manual mode
        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            let deadline = Date().addingTimeInterval(10.0)
            var success = false

            while Date() < deadline {
                if smc.writeKey(modeKey, bytes: [1]) {
                    success = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            if !success {
                throw ThermalForgeError.unlockFailed(
                    "Timed out setting fan \(i) to manual mode. Run with sudo."
                )
            }
        }
    }

    /// Unlock a single fan for manual control
    private func unlockSingleFan(_ index: Int) throws {
        if hasFtst {
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw ThermalForgeError.unlockFailed(
                    "Failed to write Ftst=1. Run with sudo."
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let deadline = Date().addingTimeInterval(10.0)

        while Date() < deadline {
            if smc.writeKey(modeKey, bytes: [1]) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw ThermalForgeError.unlockFailed(
            "Timed out setting fan \(index) to manual mode. Run with sudo."
        )
    }

    // MARK: - Set Speed

    /// Set all fans to maximum RPM
    public func setMax() throws {
        let count = try fanCount()
        try unlockFans(count: count)

        for i in 0..<count {
            let info = try fanInfo(i)
            let maxRPM = info.maxRPM > 0 ? info.maxRPM : 7826

            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            guard smc.writeKey(targetKey, bytes: floatToSMCBytes(maxRPM)) else {
                throw ThermalForgeError.writeFailed(targetKey)
            }
            log("Set fan \(i) to max (\(Int(maxRPM)) RPM)")
        }
    }

    /// Set a single fan to a specific RPM
    public func setSpeed(fan index: Int, rpm: Float) throws {
        let info = try fanInfo(index)

        // Safety: never below minimum
        if info.minRPM > 0 && rpm < info.minRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        // Safety: never above maximum
        if info.maxRPM > 0 && rpm > info.maxRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        if info.mode != "manual" {
            try unlockSingleFan(index)
        }

        let targetKey = SMCFanKey.key(SMCFanKey.target, fan: index)
        guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
            throw ThermalForgeError.writeFailed(targetKey)
        }
        log("Set fan \(index) to \(Int(rpm)) RPM")
    }

    /// Set all fans to a specific RPM
    public func setAllFans(rpm: Float) throws {
        let count = try fanCount()
        let infos = try (0..<count).map { try fanInfo($0) }

        // Every fan must accept the shared target. Validating only fan 0 can
        // produce a partial write or an internal failure when another fan has
        // a higher minimum or lower maximum.
        let minimum = infos.map(\.minRPM).filter { $0 > 0 }.max() ?? 0
        let maximum = infos.map(\.maxRPM).filter { $0 > 0 }.min() ?? 0
        if minimum > 0 && rpm < minimum {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: minimum, max: maximum
            )
        }
        if maximum > 0 && rpm > maximum {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: minimum, max: maximum
            )
        }

        try unlockFans(count: count)

        for i in 0..<count {
            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
                throw ThermalForgeError.writeFailed(targetKey)
            }
            log("Set fan \(i) to \(Int(rpm)) RPM")
        }
    }

    // MARK: - Reset

    /// Reset all fans to Apple defaults (auto mode, thermalmonitord resumes)
    public func resetAuto() throws {
        let count = try fanCount()

        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            _ = smc.writeKey(modeKey, bytes: [0])

            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            _ = smc.writeKey(targetKey, bytes: floatToSMCBytes(0))
        }

        // Reset Ftst if it exists — thermalmonitord reclaims control
        if hasFtst {
            _ = smc.writeKey(SMCFanKey.forceTest, bytes: [0])
        }
        log("Reset to Apple defaults")
    }

    // MARK: - Thermal Sensor Keys

    // MARK: - Core Diode & Hotspot Sensor Keys (Stats-aligned)

    /// Nominal CPU core diode keys across Apple Silicon generations (M1–M5) and Intel,
    /// matching the exact keys used by the open-source Stats monitor (exelban/stats).
    /// These measure the core center diode temperature and drive steady-state cooling curves.
    public static let cpuCoreKeys: Set<String> = [
        // Intel
        "TC0D", "TC0E", "TC0F", "TC0P", "TCAD",
        // Apple Silicon M1 (Tp09, Tp0T = E-cores; Tp01..Tp0b = P-cores)
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        // Apple Silicon M2 (Tp1h..Tp1l = E-cores; Tp01..Tp0j = P-cores)
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp0f", "Tp0j",
        // Apple Silicon M3 (Te05..Te0S = E-cores; Tf04..Tf4E = P-cores)
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        // Apple Silicon M4 (Te05, Te0S, Te09, Te0H = E-cores; Tp01..Tp0e = P-cores)
        "Te09", "Te0H",
        "Tp0V", "Tp0Y", "Tp0e",
        // Apple Silicon M5 (Tp00..Tp0K = Super/E-cores; Tp0O..Tp0y = P-cores)
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0a", "Tp0d", "Tp0g", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
    ]

    /// Nominal GPU core diode keys across Apple Silicon generations (M1–M5) and Intel/AMD,
    /// matching the exact keys used by the Stats monitor.
    public static let gpuCoreKeys: Set<String> = [
        // Intel / AMD
        "TCGC", "TG0D", "TGDD", "TG0H", "TG0P",
        // M1
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        // M2
        "Tg0f", "Tg0j",
        // M3
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
        // M4
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0k",
        // M5
        "Tg0U", "Tg0X", "Tg0g", "Tg1Y", "Tg1c", "Tg1g",
    ]

    /// On-die silicon junction hotspots, execution unit diodes, and complex aggregates.
    /// These are watched strictly by the thermal safety floor and emergency upper limit override.
    public static let hotspotKeys: Set<String> = [
        // Package & die aggregates
        "TCDX", "TCHP", "TCMb", "TCMz",
        // CPU core hotspot diodes (triplets)
        "Tp02", "Tp06", "Tp0A", "Tp0E", "Tp0W", "Tp0Z", "Tp0c",
        "Tp3P", "Tp3T", "Tp3X",
        "Te06", "Te0A", "Te0I", "Te0T", "Te0V", "Te0X",
        // GPU hotspots
        "TG0B", "TG0C", "TG0V", "TG1B", "TG2B",
        // SoC & Power delivery hotspots
        "TPDX", "TSCD", "TVD0",
    ]

    /// All thermal sensor keys probed for `status()`. Keys absent on a given machine
    /// return nil from `readTemp` and are skipped. Single source of truth so the
    /// daemon's safety floor reads exactly the CPU/GPU subset `status()` would.
    public static let thermalKeys: [String] = Array(
        cpuCoreKeys
            .union(gpuCoreKeys)
            .union(hotspotKeys)
            .union([
                // Memory
                "Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR", "Tm0p", "Tm1p", "Tm2p",
                // SSD
                "TH0x", "TH0A", "TH0B",
                // Ambient / Airflow / Proximity
                "TAOL", "TA0P", "TaLP", "TaRF", "TS0P",
                // Battery
                "TB0T", "TB1T", "TB2T",
            ])
    ).sorted()

    /// The CPU, GPU, and silicon safety keys watched by the thermal safety floor —
    /// includes both core diodes and silicon junction hotspots.
    public static let safetyTempKeys: [String] =
        thermalKeys.filter { key in ["TC", "Tp", "Te", "Tf", "TG", "Tg", "TP"].contains { key.hasPrefix($0) } }

    /// Thermal keys confirmed present during initialization.
    public var availableThermalKeys: [String] { supportedThermalKeys }

    /// CPU/GPU safety keys confirmed present during initialization.
    public var availableSafetyTemperatureKeys: [String] { supportedSafetyTemperatureKeys }

    /// Read one temperature key, decoding by returned size (flt 4-byte or ioft 8-byte).
    /// nil if absent, wrong size, or out of the sane 0–150°C range. Does NOT lock — the
    /// caller serializes SMC access (the daemon takes smcLock per key so a full sweep
    /// never blocks a client write for more than a single read).
    public func readTemp(_ key: String) -> Float? {
        let result = smc.readKey(key)
        guard result.success else { return nil }
        let temp: Float
        if result.size == 4 {
            temp = smcBytesToFloat(result.bytes, size: result.size)
        } else if result.size == 8 {
            temp = ioftBytesToFloat(result.bytes)
        } else {
            return nil
        }
        guard temp > 0, temp < 150 else { return nil }
        return (temp * 10).rounded() / 10
    }

    // MARK: - Status

    /// Read current fan speeds and temperatures
    public func status() throws -> ThermalStatus {
        let count = try fanCount()
        var fans: [ThermalStatus.FanStatus] = []

        for i in 0..<count {
            let info = try fanInfo(i)
            fans.append(ThermalStatus.FanStatus(
                index: i,
                actualRPM: Int(info.actualRPM),
                targetRPM: Int(info.targetRPM),
                minRPM: Int(info.minRPM),
                maxRPM: Int(info.maxRPM),
                mode: info.mode
            ))
        }

        // Probe temperature keys across all known Apple Silicon generations.
        // Keys that don't exist on a given machine are skipped automatically.
        // Labels use the raw SMC key name — no assumptions about what a key
        // means on hardware we haven't verified.
        // Probe every known thermal key (flt/ioft decoded by size in readTemp). Keys
        // that don't exist on this machine return nil and are skipped.
        var temps: [String: Float] = [:]
        for key in supportedThermalKeys {
            if let t = readTemp(key) { temps[key] = t }
        }

        return ThermalStatus(fans: fans, temperatures: temps)
    }

    // MARK: - Discover

    /// Enumerate SMC keys. Optional prefix filter skips reads for non-matching keys.
    public func discover(prefix: String? = nil) -> [DiscoveredKey] {
        let count = smc.getKeyCount()
        var keys: [DiscoveredKey] = []

        for i: UInt32 in 0..<count {
            guard let keyName = smc.getKeyAtIndex(i) else { continue }

            // Skip non-matching keys early
            if let prefix = prefix, !keyName.hasPrefix(prefix) { continue }

            let info = smc.getKeyInfo(keyName)
            let result = smc.readKey(keyName)

            keys.append(DiscoveredKey(
                key: keyName,
                size: info?.size ?? 0,
                type: info?.type ?? "????",
                bytes: result.success ? result.bytes : []
            ))
        }

        return keys
    }

    // MARK: - Hardware Info

    /// Returns detected hardware capabilities
    public var hardwareInfo: String {
        let ftst = hasFtst ? "yes (M1-M4 path)" : "no (M5+ direct mode)"
        let modeKey = modeKeyTemplate == SMCFanKey.modeLower ? "F%dmd (lowercase)" : "F%dMd (uppercase)"
        return "Ftst unlock: \(ftst), Mode key: \(modeKey)"
    }

    // MARK: - Private Helpers

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        let key = SMCFanKey.key(template, fan: fan)
        let result = smc.readKey(key)
        guard result.success else { return 0 }
        return smcBytesToFloat(result.bytes, size: result.size)
    }

    private func log(_ message: String) {
        TFLogger.shared.fan(message)
    }
}
