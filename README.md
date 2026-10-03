# ThermalForge

**ThermalForge is a local-use fork of [ProducerGuy/ThermalForge](https://github.com/ProducerGuy/ThermalForge), with a more proactive thermal policy for Apple Silicon Macs.** It keeps the smooth shape of the system curve while engaging earlier and reaching higher fan speeds sooner. The working goal is to preserve sustained thermal performance and reduce repeated hot cycles, accepting more fan noise than Apple's quieter default behavior.

**Free, open-source fan control for Apple Silicon Macs.** Menu bar app + CLI.

Built in 2026 with Swift. No subscriptions, no telemetry, no ads.

[![CI](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml/badge.svg)](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-orange)](https://support.apple.com/en-us/116943)

---

## Why ThermalForge?

Tools like **Macs Fan Control** and **TG Pro** charge $15–$20 for fan control that hasn't fundamentally improved in years. Both require manual configuration, neither learns anything about your machine, and both have documented problems on Apple Silicon.

| Feature | ThermalForge | Macs Fan Control | TG Pro |
|---|---|---|---|
| Adaptive fan curve | **Yes** | No | No |
| Thermal calibration measurement (CLI) | **Yes** | No | No |
| Multi-sensor safety | **Yes — all CPU/GPU silicon sensors** | [One sensor per fan](https://github.com/crystalidea/macs-fan-control/issues/266) | Manual rules only |
| Proactive cooling (ramps before throttle) | **Yes** | No | No |
| Fan curve type | Per-profile point curves + sustained-load trim | Linear between 2 points | Manual step-function |
| Real-time temp monitoring | Yes | Yes | Yes |
| Menu bar app | Yes | Yes | Yes |
| CLI access | **Yes** | No | No |
| Thermal data logging (CSV) | **Yes** | No | Yes |
| Sleep/wake re-apply | Yes | Yes | Yes |
| Hotspot safety override | **Yes — daemon-enforced, works with app closed** | No | Requires manual setup |
| Crash recovery (heartbeat watchdog) | **Yes — daemon-enforced, holds during overheat** | Reverts on quit only | Override removes macOS safety |
| Open source | **Yes** | No | No |
| Price | **Free** | $15 | $20 |

### Known problems with alternatives

**Macs Fan Control** monitors only one temperature sensor per fan. Users have reported [GPU overheating while monitoring CPU only](https://github.com/crystalidea/macs-fan-control/issues/266), leading to system lockups. Fan control is [broken on M3/M4 Pro and Max](https://github.com/crystalidea/macs-fan-control/issues/785) due to Apple firmware changes.

**TG Pro** offers more flexibility but requires users to manually configure step-function rules for each fan speed threshold. Its "Override System" mode removes macOS thermal safety entirely — if your rules are wrong, there's no backstop. No learning, no adaptation, no calibration.

**AlDente Pro** ($30) is a battery management tool with no fan control features. It monitors battery temperature and pauses charging — it does not control fans.

## Features

- Real-time CPU, GPU, hotspot, battery, RAM, SSD, and ambient temperatures in the menu bar
- Three profiles (Quiet, Default, Performance), each a simple temperature → fan-level curve with a live preview showing where the machine is on it
- Control that also responds to sustained load, rising temperature, battery temperature, and macOS thermal pressure — the menu shows which one is driving the fans
- Separate profiles on battery and on the power adapter, with an optional adapter boost
- Apple Auto when cool: below each profile's takeover point macOS keeps control, so the fans can stop completely
- Self-healing control: failed fan commands are retried, the daemon re-acquires the fans if macOS takes them back, and nothing latches ThermalForge out of your chosen mode
- Hotspot safety override (full speed, clears itself once cool), also enforced by the background daemon when the app is closed
- Crash recovery: the daemon's heartbeat watchdog returns the fans to Apple Auto if the app stops
- Thermal logging — CSV + JSON data export for research
- Automatic fan re-apply after sleep/wake
- Privileged daemon — one-time admin prompt, no password prompts after
- Native Swift — lightweight, no Electron

## Profiles

A fan **level** is a position in the fan's own range: 0% is the hardware minimum RPM, 100% the maximum. The menu, the manual slider, and the curves all use this scale. Curves are evaluated against the smoothed hottest CPU/GPU core diode (the Stats-style core temperature, not the junction hotspot).

| Profile | Takeover → Apple Auto again | Curve (core °C → fan level) | Sustained target | Notes |
|---|---|---|---:|---|
| **Quiet** | 78°C for 15 s → ≤68°C for 45 s | 78→0%, 84→25%, 90→50%, 95→75%, 99→100% | 90°C | Stays out longest; still far cooler than Apple Auto under load. |
| **Default** | 70°C for 10 s → ≤62°C for 30 s | 70→0%, 76→15%, 82→40%, 88→65%, 93→85%, 97→100% | 84°C | About 32% at 80°C (40% with the adapter boost). |
| **Performance** | 62°C for 5 s → ≤55°C for 30 s | 62→0%, 68→15%, 75→45%, 82→75%, 88→100% | 78°C | Loudest; keeps sustained work coolest. |

These were tuned on an M4 MacBook Pro against measured Apple Auto behavior: it keeps the fan off for light work, and under a sustained full load it let the core reach 105–109°C and the TCMz hotspot about 115°C while slowly raising the fan from ~2,800 to ~5,000 RPM over 90 seconds. The profiles stay out of light work the same way, then respond much earlier so sustained loads run far cooler. They are starting points, not proven optimums for every Mac.

Run only one fan controller at a time. If TG Pro or Macs Fan Control is running, the menu warns you: both apps write fan targets and will fight.

On top of the curve, every profile applies:

- **Smoothing** — a fast-rising (4 s) and slow-falling (20 s) average of the core temperature, so a one-second spike doesn't spin the fans up and a brief pause between bursts doesn't spin them down.
- **Sustained-load trim** — while the smoothed temperature stays above the profile's target, fan level slowly increases (up to +40%) until it comes back down; it decays once the machine is cooler. This is what keeps long workloads from creeping up and cycling hot.
- **Rising-temperature boost** — Default and Performance add a little fan level while temperature climbs quickly.
- **Battery** — `TB*` battery temperature raises the minimum level from 38°C to full speed at 40°C. This is a conservative policy, not a published damage threshold; Apple publishes ambient operating ranges but no universal battery-pack degradation cutoff.
- **macOS thermal pressure** — when macOS reports fair, serious, or critical thermal pressure (`ProcessInfo.thermalState`), the level is at least 30%, 80%, or 100%.
- **Adapter boost** (optional, on by default) — on the power adapter the profile level becomes `level × 1.10 + 5 points`. It never lifts minimum speed.
- **Ramp limits** — each profile limits how fast the level rises and falls, and takeover starts from the speed Apple Auto was already running, so the fans never jump.

SSD, memory, ambient, and power-delivery sensors are shown and logged but do not drive the fans.

In **Settings** you can keep control at minimum speed instead of handing back to Apple Auto, or set one custom takeover temperature for every profile.

The control loop runs every 100 ms; a full SMC sensor snapshot is taken every second from keys found at startup. Both are adjustable under **Refresh**.

To add a profile, define a `FanProfile` and append it to `FanProfile.available`. The controller, pickers, and preview all use that registry.

### Safety

If the hottest CPU/GPU silicon sensor (including junction hotspots such as `TCMz`) stays at or above the safety limit (default 105°C, adjustable 90–115°C) for 2 seconds, fans run at full speed. When it has been at least 8°C below the limit for 10 seconds, fans ramp back to your profile or manual level. It never locks you out of your mode, and it alerts you at most once every ten minutes. The background daemon enforces the same limit on its own if the app stops.

Apple Auto mode means exactly that: ThermalForge only monitors.

## Install

### Upstream Homebrew package (not this fork)

```bash
brew tap ProducerGuy/tap
brew trust --formula ProducerGuy/tap/thermalforge
brew install thermalforge
sudo thermalforge install
```

Homebrew requires third-party taps to be trusted before it will run their formula, which is the `brew trust` step (per-formula, Homebrew's recommended form). `brew install` builds and installs the **CLI**. `sudo thermalforge install` then sets up the background daemon (so the app can control fans without a password every time) **and copies the menu bar app into `/Applications`**. You only run it once.

### Build this fork locally

For local use without an Apple Developer account, build an ad hoc signed app bundle:

```bash
git clone https://github.com/XInTheDark/ThermalForge.git
cd ThermalForge
./Scripts/build_local.sh
open ./dist/ThermalForge.app
```

The script builds the release CLI and menu bar app, embeds a copy of the CLI for the app’s one-click daemon installer, assembles `dist/ThermalForge.app`, removes quarantine attributes, and signs the bundle with an ad hoc identity (`-`). This is suitable for the Mac where it was built; it is not a distribution or notarization workflow. If the daemon is missing, the app shows an **Install Service** button that opens the normal macOS administrator prompt. You can also install it from Terminal with `sudo ./dist/thermalforge install`.

Use `./setup.sh` when you want the CLI, daemon, and app installed into system locations; it requires one administrator password prompt.

### After install

Open ThermalForge from Spotlight, Finder (Applications > ThermalForge), or terminal:

```bash
open /Applications/ThermalForge.app
```

Turn on **Launch at Login** in the menu bar dropdown and it starts automatically on every boot.

## Security

ThermalForge controls fans through a background daemon, and 0.2.0 locks down how you talk to it:

- **Private control socket.** The daemon listens on `/var/run/thermalforge.sock`, mode `0600`, owned by the user who ran `sudo thermalforge install`. Only that user and root can send fan commands — no other local account can drive your fans.
- **Structured, versioned protocol.** The CLI, app, and daemon speak a size-capped, versioned message format. Oversized or malformed input is rejected rather than parsed, and a version mismatch surfaces as an "Update needed" prompt instead of silent divergence.
- **Safety enforced in the daemon.** RPM requests above a fan's maximum are clamped in the daemon, not just the app. Commands are rate-limited. A thermal floor forces fans to maximum if a CPU/GPU silicon sensor reaches the safety limit while a manual hold is keeping them too low — and it runs in the background service, so it works even with the menu bar app closed.
- **Robust connection handling.** Connections are handled concurrently, bounded, and timed out, so a stuck or slow client can't stall fan control.

### FAQ

**What if ThermalForge closes during normal use?**
The daemon's heartbeat watchdog detects the app is gone within 15 seconds and resets fans to Apple defaults. On next launch, the app syncs to whatever the daemon is currently holding rather than forcing a reset — so a hold you set deliberately (e.g. `sudo thermalforge max`) survives. If the daemon's thermal floor is holding fans at maximum when the app dies, the watchdog defers the reset until the machine has cooled — it never drops fans back to auto while the machine is hot.

**What if a fan command fails?**
ThermalForge keeps your mode and retries (0.5 s, 1 s, 2 s, … then every 10 s), showing a "Retrying fan commands" note if it persists. If the daemon restarts or macOS takes the fans back (for example after wake), ThermalForge notices the fans aren't following and sends the setting again.

### Resets and troubleshooting

**Reset fans right now:**
```bash
thermalforge auto
```
Resets the fans to Apple defaults and leaves your menu bar app running. Add `--stop-app` if you also want to quit the app so the reset sticks — otherwise a running profile re-applies its curve within seconds. With `--stop-app` the menu bar icon disappears (that's expected); relaunch from Spotlight or `/Applications` when you're done.

**Fans loud and won't stop? Reset them now:**
```bash
sudo killall ThermalForgeApp; sudo /usr/local/bin/thermalforge auto
```
This always works, even if the app isn't running. It stops ThermalForge and hands fan control straight back to macOS — your fans will settle to normal within a few seconds. It writes directly to the hardware, so it doesn't depend on the app or the background service being healthy.

**Completely remove ThermalForge:**
```bash
sudo thermalforge uninstall
```
Removes the daemon, binary, app, and all logs. Clean slate.

If installed via Homebrew, run `brew uninstall thermalforge` first.

**"Update needed" after a Homebrew upgrade:** `brew upgrade` updates the app and CLI, but the background daemon keeps running the old build until you re-sync it. While they differ, the menu bar shows an **"Update needed"** banner and the CLI prints a version-mismatch warning, both naming the two versions. Fix it once with `sudo thermalforge install`; the banner clears when they match again.

### Disclaimer

ThermalForge is provided as-is with no warranty. Use at your own risk.

## CLI

```bash
thermalforge status        # JSON output: fan speeds + temps
thermalforge max           # Max fans — no sudo when the daemon is running
thermalforge auto          # Reset to Apple defaults
thermalforge set 4000      # Set specific RPM — no sudo when the daemon is running
thermalforge discover      # Dump all SMC keys (for new hardware)
thermalforge watch         # Run a profile from the terminal (sudo; --dry-run to preview without sudo)
thermalforge log           # Record thermal data to CSV (1Hz, auto-delete 24h)
thermalforge log --rate 10 --duration 1h --no-expire   # 10Hz for 1 hour, keep forever
```

`max` and `set` need root to unlock the fans, so when the daemon is installed they route through it and **don't need `sudo`**; without a daemon (e.g. an uninstalled from-source build) they write the hardware directly and need `sudo`. `auto` also routes through the daemon but never needed the unlock — resetting just hands control back to macOS. `watch` always needs `sudo` (it runs its own root monitor loop). Control a single fan with `--fan`, e.g. `thermalforge set 3000 --fan 1`.

Fans settle **near** a commanded target rather than exactly on it, so `status` and the menu bar report an RPM slightly above or below what you set — that's the live tach reading, not an error.

Set fans from the terminal and the menu bar app shows a **"Fans held from Terminal"** banner and pauses its automatic control so it won't fight you — choose a mode in the menu (Profile, Apple Auto, or Manual) to take over.

## Compatibility

Tested on MacBook Pro M5 Max (Mac17,7). Should work on M1–M5 MacBooks.
Run `thermalforge discover` on your machine and [submit a compatibility report](../../issues/new?template=compatibility-report.md).

| Machine | Chip | Status |
|---|---|---|
| MacBook Pro 16" (2025) | M5 Max | Tested |
| Mac Studio (2022) | M2 Ultra | Tested |
| MacBook Pro 16" (2021) | M1 Max | Tested |
| MacBook Pro 16" M5 Pro (Mac17,8) | M5 Pro | Reported |
| MacBook Pro 14" M5 Pro (Mac17,9) | M5 Pro | Reported |
| MacBook Pro M4 Max (Mac16,5) | M4 Max | Reported |
| MacBook Pro M3 Max (2023, 128GB) | M3 Max | Reported |
| MacBook Pro 14" M2 Pro (2023) | M2 Pro | Reported |
| MacBook Pro 14" M2 Max (2023) | M2 Max | Reported |
| MacBook Pro M1 (2020) | M1 | Reported |

SMC key names vary across chip generations — ThermalForge auto-detects at startup. The `discover` command dumps all keys so we can verify what your hardware uses. The more machines tested, the more robust ThermalForge becomes.

## Uninstall

### Homebrew

```bash
brew uninstall thermalforge
sudo thermalforge uninstall
```

`thermalforge uninstall` removes the daemon, binary, app, calibration data, and all logs.

### From source

```bash
sudo thermalforge uninstall
```

This removes the daemon, binary, app bundle, calibration data, and all logs.

## Contributing

ThermalForge is a solo project but compatibility reports are hugely valuable. If you have an Apple Silicon Mac:

1. Install ThermalForge
2. Run `thermalforge discover --output discover.txt`
3. [Open a compatibility report](../../issues/new?template=compatibility-report.md) and attach the file

That's it. Every new machine tested makes ThermalForge better for everyone.

## Thermal Logging

No existing macOS tool exports structured thermal data with process correlation in a format designed for research. ThermalForge does.

### Who this is for

- **Data scientists** studying thermal behavior across Apple Silicon generations
- **Hardware engineers** validating cooling solutions or thermal pad mods
- **Developers** profiling how their apps affect system thermals
- **Researchers** who need reproducible, citable thermal data for papers

### What it captures

```bash
thermalforge log                                          # 1Hz, auto-delete after 24h
thermalforge log --rate 10 --duration 1h --no-expire      # 10Hz, 1 hour, keep forever
```

Each session produces a self-contained folder:

| File | Contents |
|---|---|
| **thermal.csv** | Timestamped readings from every detected temperature sensor, fan RPM (actual + target), fan mode, at every sample interval |
| **processes.csv** | Top 5 processes by CPU utilization at every sample — the missing link between thermal data and what caused it |
| **metadata.json** | Machine model, chip, OS version, ThermalForge version, fan count, RPM range, sample rate, complete sensor dictionary, session start/end, total sample count |

### Why this format

- **CSV + JSON sidecar** — loads directly in pandas, R, Excel, or any data tool without a custom parser
- **Raw SMC key names** — no friendly labels that could be wrong across chip generations. Cross-reference against Apple hardware documentation directly
- **Self-describing sessions** — every log folder contains everything needed to interpret the data. Hand it to someone with no context and they can work with it
- **Auto-delete by default (24h)** — prevents disk bloat for casual users. `--no-expire` for researchers who need to keep data

### Storage

ThermalForge has three types of stored data, all automatically managed:

**App log** (daily files in `~/Library/Logs/ThermalForge/`) — one file per day (`thermalforge-2026-04-05.log`). Records app events: mode and profile changes, takeovers and hand-backs, safety overrides, thermal-pressure and power-source changes, and fan command failures. Auto-deletes files older than 7 days on app launch. Each daily file is small and easy to open or share.

**Research session logs** (`thermalforge log` exports in `~/Library/Application Support/ThermalForge/logs/`) — CSV/JSON research data. Auto-delete after 24 hours by default. Use `--no-expire` to keep permanently.

Nothing accumulates indefinitely. All cleanup runs automatically on app launch.

## Future Specs

### Enhanced Logging

- **Thermal throttle state** — capture Apple's `ProcessInfo.thermalState` (nominal/fair/serious/critical) at every sample. Know exactly when and how hard the chip throttled.
- **Power draw** — SMC power keys (PSTR, PCPT) to capture wattage alongside temperature. Watts correlate directly with heat generation.
- **GPU utilization** — current logging captures CPU processes but GPU compute workloads (Metal, ML inference) are invisible. GPU utilization fills that gap.
- **Memory pressure** — system memory pressure percentage at every sample
- **Delta-T over ambient** — report temperatures as both absolute and delta above ambient. This is the standard comparison metric used by hardware reviewers (Gamers Nexus, Notebookcheck) because absolute temps vary with room temperature.
- **User markers** — annotate the log mid-session ("started render", "switched profile") so data points have context when analyzed later
- **Statistical summary** — min, max, mean, standard deviation, P95/P99 for all sensors across the session. Time spent in each thermal state. Peak fan RPM.

### Experiment Mode

A controlled testing framework for anyone who wants to understand their Mac's thermal behavior — modders validating thermal pad swaps, developers profiling their apps, engineers comparing cooling strategies.

```bash
thermalforge experiment --workload cpu --fan default --duration 10m --label "default-baseline"
thermalforge experiment --workload cpu --fan 75%  --duration 10m --label "fixed-75"
thermalforge compare default-baseline fixed-75
```

**Controlled variables:**
- Fan speed: any profile, fixed percentage, or Default
- Workload type: CPU stress, GPU stress (Metal compute), CPU+GPU combined, idle baseline, or any custom command
- Duration with automatic steady-state detection (temp change <0.5°C over 2 minutes)
- Ambient temperature input for Delta-T calculations

**Metrics generated per experiment:**
- Time-to-throttle — how long before the chip starts losing performance
- Time-to-steady-state — how long before temperature stabilizes
- Sustained performance score — average clock throughput over the test duration
- Statistical summary — mean, std dev, min, max, P95/P99 temps

**Comparison reports:**
- Side-by-side A/B results across experiments
- Automatic detection of statistically significant differences
- Export as CSV or formatted summary

**Built-in workloads:**
- CPU stress: saturates all cores with compute-bound work
- GPU stress: Metal compute shaders that load the GPU pipeline
- Combined: CPU + GPU simultaneously (the real-world worst case for Apple Silicon where CPU, GPU, and Neural Engine share the same die and unified memory)
- Idle baseline: 5-minute idle measurement before and after tests to establish reference

### Community Thermal Database

Opt-in anonymous upload of experiment results. Compare your machine against others with the same chip. See how your M5 Max thermal performance ranks against the distribution. Modeled after [OpenBenchmarking.org](https://openbenchmarking.org) — standardized methodology, community validation, machine fingerprinting by chip model (not serial number).

See [ROADMAP.md](ROADMAP.md) for full specs and build plans.

## License

[MIT](LICENSE) — free to use, modify, and distribute.
