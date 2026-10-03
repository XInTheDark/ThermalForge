# ThermalForge fork guidance

This repository is a fork of [ProducerGuy/ThermalForge](https://github.com/ProducerGuy/ThermalForge). Its goal is a system-like, smooth fan response that is more proactive about cooling: preserve sustained thermal performance and reduce repeated hot cycles, accepting more fan noise than Apple's quieter default behavior. Do not treat inherited thresholds, calibration claims, or profile descriptions as proven for this fork. Validate them against the implementation and measured hardware behavior.

## Keep profile work simple

- Define profiles in `Sources/ThermalForgeCore/Profile.swift` and register them in `FanProfile.available`. The shipped profiles are Quiet (`silent`), Default (`default`), and Performance (`aggressive`); unknown or legacy ids resolve to Default.
- A profile is data: curve points (smoothed core °C → fan level, where level 0 is minimum RPM and 1 is maximum), takeover/release temperatures and delays, sustained-load target, ramp rates, and rising-temperature boost. Tune profiles through that data. Do not add profile-name or profile-id branches to the controller, monitor, app, or CLI.
- `FanController` is the only place the control law lives. Keep it pure (no timers, SMC, or sockets) and covered by focused tests. The menu preview uses the same `Curve.level(at:)` and must say it is a steady-temperature estimate.
- Document meaningful tuning changes (README Profiles table) and update `ProfileTests`/`FanControllerTests`.
- Preserve the hotspot safety override, daemon watchdog and thermal floor, Terminal-hold arbitration, and Apple Auto handback. Profile tuning must not bypass them.
- Never latch control off. Failed commands are retried by `FanActuator`; lost sensors hand the fans to Apple Auto until readings return; the safety override clears itself.

## Implementation and verification

Make the smallest change that solves the requested problem. Preserve unrelated edits. Trace the actual app-to-monitor-to-daemon path before changing fan behavior. Keep blocking I/O off the main actor.

Commands flow app → `ThermalMonitor` (controller step) → `FanActuator` (desired-state reconciliation, backoff) → `DaemonClient` → daemon → `FanControl`. `FanControl` re-acquires manual control only when needed: when `Ftst` is not set, a fan is not in manual mode, or a settled target no longer matches what it wrote (macOS took the fan back). On Apple Silicon the mode key reads 1 even while macOS drives the fan, so it is not proof of control.

Sensor snapshots and the control loop are independent settings. Defaults are 1 second and 100 milliseconds respectively. Cache supported SMC thermal keys at startup; do not restore repeated probing of every candidate key. Avoid unnecessary polling, repeated writes, and extra background work.

The controller uses smoothed nominal CPU/GPU core diodes (matching the open-source Stats model: `Te*`/`Tf*`/`Tp*` core center diodes across M1–M5) for the main cooling curve and primary UI display. Sensor resolution is platform-aware (detected via `machdep.cpu.brand_string`) to prevent cross-generation key collisions (such as `Tp0f`, which is a core diode on M2 but a hotspot on M4/M5). This ensures a system-like, smooth response without fan "yo-yoing" on sub-second execution spikes when heatsinks are still cool. Peak silicon hotspots (`Tp0W`, `Tp0f`, `TCMz`, package aggregates) drive only the safety override (sustained 2 s at the limit, cleared 8°C below for 10 s) and the daemon thermal floor. Other sensors (power delivery, SSD, battery) must never trigger the silicon safety override. macOS thermal pressure (`ProcessInfo.thermalState`) sets fan-level floors of 30/80/100% for fair/serious/critical. The `TB*` battery sensor acts as a separate cooling constraint, and fan minimum/maximum RPM enforce hardware limits. SSD, memory, ambient, and power-delivery sensors are displayed and logged but do not currently drive the curve. Power source is read through IOKit, not by spawning `pmset`. Battery cooling starts increasing demand at 38°C and reaches full demand at 40°C as a conservative policy; Apple publishes recommended ambient ranges, but does not publish a universal battery-pack degradation cutoff, so do not describe 38–40°C as a hard damage threshold.

Battery and external-power profile choices are separate. A `FanPercentTransform` applies `level × multiplier + shift`, clamped to 0–100%, to positive levels only. The default adapter transform is ×1.10 plus 5 percentage points; it can be disabled in the app. Keep this transform after the base curve and battery constraint so a profile remains reusable in both modes.

`thermalforge watch --dry-run -p <id>` runs a profile against live sensors without writing to the fans (no root); use it to sanity-check tuning.

Use lightweight checks during development. Run focused tests for changed behavior, then `swift test` and `git diff --check` before delivery. Build only when needed to validate compile or packaging changes; a rebuild is not required after every edit.

For a local packaged app without a paid Apple Developer account, use `./Scripts/build_local.sh`. It creates the ad hoc signed app and bundled CLI in `dist`. This is a local-use workflow, not distribution or notarization. The app offers installation of the privileged daemon through the normal macOS administrator prompt.

Do not commit or push unless requested. Report the exact commit and remote status when asked to commit or push.
