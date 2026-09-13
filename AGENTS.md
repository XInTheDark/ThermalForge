# ThermalForge fork guidance

This repository is a fork of [ProducerGuy/ThermalForge](https://github.com/ProducerGuy/ThermalForge). Its goal is a system-like, smooth fan response that is more proactive about cooling: preserve sustained thermal performance and reduce repeated hot cycles, accepting more fan noise than Apple's quieter default behavior. Do not treat inherited thresholds, calibration claims, or profile descriptions as proven for this fork. Validate them against the implementation and measured hardware behavior.

## Keep profile work simple

- Define profiles in `Sources/ThermalForgeCore/Profile.swift` and register them in `FanProfile.available`.
- The only shipped starting profile is `Default`. Legacy profile ids resolve to it.
- Add or tune profiles through curve data. Do not add profile-name or profile-id branches to the monitor, app, or CLI.
- Keep curve math shared between control and the visual preview. The preview must say that it is a steady-temperature estimate; live output also depends on hysteresis, sustained heat, ramp limits, hardware minimum RPM, and calibration.
- Put each profile's start, stop, ceiling, shape, ramp rates, sustained trigger, and rising-temperature boost together. Document meaningful tuning changes and add focused curve tests.
- Preserve safety overrides, watchdog behavior, command arbitration, and return-to-auto handling. Profile tuning must not bypass them.

## Implementation and verification

Make the smallest change that solves the requested problem. Preserve unrelated edits. Trace the actual app-to-monitor-to-daemon path before changing fan behavior. Keep blocking I/O off the main actor.

Sensor snapshots and the control loop are independent settings. Defaults are 1 second and 100 milliseconds respectively. Cache supported SMC thermal keys at startup; do not restore repeated probing of every candidate key. Avoid unnecessary polling, repeated writes, and extra background work.

The controller uses the peak CPU/GPU safety sensors for the main curve, the `TB*` battery sensor as a separate cooling constraint, and fan minimum/maximum RPM for hardware limits. SSD, memory, ambient, and power-delivery sensors are displayed and logged but do not currently drive the curve. Power source is read through IOKit, not by spawning `pmset`. Battery cooling starts increasing demand at 38°C and reaches full demand at 40°C as a conservative policy; Apple publishes recommended ambient ranges, but does not publish a universal battery-pack degradation cutoff, so do not describe 38–40°C as a hard damage threshold.

Battery and external-power profile choices are separate. A `FanPercentTransform` applies `target × multiplier + shift`, clamped to 0–100%. The default adapter transform is ×1.10 plus 5 percentage points; it can be disabled in the app. Keep this transform after the base curve and battery constraint so a profile remains reusable in both modes.

Use lightweight checks during development. Run focused tests for changed behavior, then `swift test` and `git diff --check` before delivery. Build only when needed to validate compile or packaging changes; a rebuild is not required after every edit.

For a local packaged app without a paid Apple Developer account, use `./Scripts/build_local.sh`. It creates the ad hoc signed app and bundled CLI in `dist`. This is a local-use workflow, not distribution or notarization. The app offers installation of the privileged daemon through the normal macOS administrator prompt.

Do not commit or push unless requested. Report the exact commit and remote status when asked to commit or push.
