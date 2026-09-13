import Foundation
import IOKit.ps

public enum PowerSourceState: String, Codable, Sendable {
    case battery
    case external
}

/// Reads the system power source without spawning a process. The result is used
/// only to choose between the battery and adapter profile settings.
public enum SystemPowerSource {
    public static var current: PowerSourceState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey as String] as? String,
               state == kIOPSACPowerValue as String {
                return .external
            }
        }
        return .battery
    }
}
