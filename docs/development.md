# Development bootstrap

PSD currently has a minimal real Qt 6/QML runtime, a Hyprland compositor-state bridge, and an opt-in compositor transform/gesture experiment. It is not yet a complete desktop session and the compositor integration is not yet production-validated.

## Baseline

- Ubuntu 26.04
- Qt 6.10 or newer within the Qt 6 series
- C++20
- CMake
- Ninja
- Hyprland 0.53.x runtime target on Ubuntu 26.04 for integration testing

## Ubuntu 26.04 dependencies

Core build:

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build qt6-base-dev qt6-declarative-dev qt6-wayland liblayershellqtinterface-dev
```

For real compositor integration tests:

```bash
sudo apt install hyprland xdg-desktop-portal-hyprland
```

Hyprland is not yet a compile-time dependency of `psd-core`.

## Configure

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
```

## Build

```bash
cmake --build build
```

## Test

```bash
ctest --test-dir build --output-on-failure
```

## Run the current shell bootstrap

From the repository root after building:

```bash
./build/psd-shell
```

Outside a Hyprland session the shell still starts, but the compositor bridge reports offline.

Inside Hyprland, the runtime discovers the current instance through:

- `HYPRLAND_INSTANCE_SIGNATURE`;
- `XDG_RUNTIME_DIR`.

It then connects to Hyprland's documented command and event UNIX sockets.

## Implemented now

- Qt 6 application/runtime startup;
- embedded canonical Spatial Glass design-token loading;
- shared C++ spatial state;
- shared C++ spatial geometry and animation authority;
- one Wayland `wlr-layer-shell` surface per connected `QScreen` through LayerShellQt;
- independent spatial state/layout/motion per monitor;
- live screen add/remove handling;
- QML shell root;
- persistent CENTER/LEFT/RIGHT/TOP/DASH object structure;
- mouse gutter dwell navigation;
- continuous 1:1 gesture progress in the C++ motion controller, including axis lock and distance/velocity snap decisions;
- rigid translation between shell surfaces driven by a single C++ motion controller;
- CENTER return semantics;
- per-monitor transparent return shield preventing displaced apps from receiving the first click;
- per-monitor explicit-fullscreen suppression: immediate CENTER reset plus shell/shield unmap until fullscreen exits;
- generic internal compositor bridge abstraction;
- Hyprland IPC state backend;
- monitor/workspace/window normalization;
- live event socket;
- opt-in four-finger swipe event bridge from the Hyprland plugin into the monitor-local motion controller;
- compositor-generic transform commands behind `CompositorBridge`, with command IDs and per-monitor serialization;
- final-reset draining when experimental sync is disabled, a monitor disappears, or the shell exits normally;
- SIGTERM/SIGINT conversion into orderly Qt shutdown so compositor cleanup can run;
- plugin-side tracking of the exact workspace PSD transformed, avoiding reset of the wrong active workspace;
- experimental `j/psd-plugin-state` diagnostics for integration probes without exposing Hyprland internals as a PSD API;
- event-coalesced state refreshes;
- no compositor polling loop;
- unit tests for tokens, spatial state, responsive geometry, motion authority, Hyprland protocol parsing and compositor reset sequencing;
- GitHub-hosted Ubuntu 26.04 KVM/QEMU integration with guest DRM/KMS, seatd, Hyprland, the real Qt/Wayland shell and compositor plugin;
- deterministic Qt/Wayland integration client used to keep workspaces alive and request fullscreen during compositor lifecycle validation.

## Current compositor boundary

The normal compositor state/introspection path is read-only. Experimental render-offset commands are available only when the PSD Hyprland plugin is loaded and explicitly enabled.

The read-only path currently issues:

- `j/monitors`;
- `j/workspaces`;
- `j/clients`.

The repository now contains a monitor-scoped compositor render-offset proof of concept. It remains disabled by default. Set `PSD_EXPERIMENTAL_HYPRLAND_SYNC=1` only in a matching Hyprland test session after loading `psd-hyprland-plugin`.

See `docs/compositor-bridge.md`.

## What is not implemented yet

- production login/session entry;
- validated production compositor-level spatial transform;
- production adoption of the experimental Hyprland render-offset mechanism;
- real desktop icons/files;
- notifications/control center/search providers;
- real-session validation/tuning of the four-finger touchpad gesture feed;
- public D-Bus/IPC automation.

Those are subsequent implementation milestones and must use the versioned contracts in `docs/` and `spec/`.

## GitHub-hosted compositor integration

GitHub-hosted containers still do not expose a useful DRM render node directly, but PSD no longer treats that as a blocker.

The `ubuntu-26-04-qemu` CI job boots the pinned Ubuntu Minimal 26.04 release inside QEMU/KVM. The guest receives a Virtio DRM/KMS device and runs:

- Ubuntu 26.04.1 userspace;
- `seatd` for compositor ownership of the virtual DRM seat;
- Hyprland 0.53.x on the guest's native Virtio DRM/KMS output;
- the ABI-sensitive PSD Hyprland plugin;
- the real `psd-shell` over Qt Wayland;
- the live compositor lifecycle probe.

The image URL is release-dated rather than `current`, and the harness verifies the cached/downloaded QCOW2 against Canonical's `SHA256SUMS` before booting it.

The VM validates compositor semantics and lifecycle. It does **not** validate physical-device properties such as touchpad feel, NVIDIA-specific behavior, direct-scanout performance, VRR, real mixed-DPI displays or perceptual latency.

`tests/integration/probe-hyprland-plugin.sh` remains useful independently on any Linux machine exposing a DRM render node. The manual `.github/workflows/vm-integration.yml` workflow runs the same QEMU harness on demand.

## Live-session integration probe

For the checks that genuinely require a running compositor, use the real-session probe from inside the Hyprland session under test:

```bash
bash tests/integration/probe-live-session.sh
```

Default paths are `build/psd-shell` and `build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so`; both can be passed explicitly as the first and second arguments.

The probe:

- refuses to create a duplicate PSD shell if one is already mapped;
- loads the PSD plugin only when needed and unloads only what it loaded;
- validates protocol v3 capabilities plus the experimental diagnostic-state capability;
- requires the plugin transform state to be clean before starting;
- launches `psd-shell` with experimental compositor sync enabled;
- verifies exactly one `psd-shell:<output>` layer surface for every active Hyprland monitor;
- verifies the shell starts in CENTER with every `psd-return-shield:<output>` surface unmapped;
- verifies the four-finger gesture arm/disarm dispatcher;
- cleans up the shell and experimental gesture interception on exit;
- resets every transform reported by the plugin plus every currently active monitor before finishing, so cleanup also covers a tracked output that disappeared during the probe; this applies even when the plugin was already loaded by the session.

It does not move application windows by default. To include a small direct 24-logical-unit plugin offset/state/reset smoke test on the focused monitor:

```bash
PSD_PROBE_EXERCISE_OFFSET=1 bash tests/integration/probe-live-session.sh
```

For the stronger runtime lifecycle test, run:

```bash
PSD_PROBE_EXERCISE_RUNTIME=1 bash tests/integration/probe-live-session.sh
```

That opt-in mode uses the real shell input path rather than a test-only shell API. On the focused monitor it:

1. records the current workspace and cursor position;
2. switches to a temporary named workspace;
3. optionally maps the deterministic `psd-integration-client` there so the previous workspace remains alive;
4. moves the Hyprland cursor into the LEFT gutter and waits for the real ~180 ms dwell navigation;
5. requires the return shield and exactly one non-zero compositor transform to appear;
6. switches to a second workspace while PSD remains displaced;
7. requires a new workspace generation; when the previous workspace remains alive, it also requires an explicit previous-workspace reset;
8. when the integration client is available, requests real Wayland fullscreen and requires PSD surfaces to unmap plus the compositor transform to reset;
9. requires fullscreen exit to remap a clean CENTER shell;
10. with `PSD_PROBE_EXERCISE_CRASH_RECOVERY=1`, displaces CENTER again, kills `psd-shell` with SIGKILL, restarts it, and requires startup recovery to clear any residual compositor transform and map clean CENTER;
11. sends SIGTERM to the recovered shell and requires zero tracked transforms afterward;
12. restores the original workspace and cursor position.

With `PSD_PROBE_EXERCISE_HOTPLUG=1`, the same live shell also receives a temporary headless output. The probe requires its independent CENTER surface to appear, verifies the primary monitor is the only transformed output during navigation, and removes the temporary output again while the shell is still alive.

The QEMU CI enables the deterministic client, hotplug and SIGKILL-recovery paths automatically. On arbitrary real hardware those paths remain opt-in so the probe does not create windows or virtual outputs unless explicitly requested.

GitHub-hosted CI also runs `tests/integration/test-probe-live-session-mock.sh`. That test uses a fake `hyprctl` and fake shell process only to validate the probe's control flow, cleanup ownership, CENTER-layer expectations and error handling. It is not compositor validation and does not replace the real-session probe.

This probe is the preferred entry point before declaring the current compositor experiment valid on real hardware.
