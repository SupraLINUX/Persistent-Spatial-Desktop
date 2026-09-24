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
- mouse gutter dwell navigation through four thin monitor-local LayerTop input surfaces, separated from the LayerBackground shell so normal application windows cannot steal gutter hover;
- continuous 1:1 gesture progress in the C++ motion controller, including axis lock and distance/velocity snap decisions;
- rigid translation between shell surfaces driven by a single C++ motion controller;
- CENTER return semantics;
- per-monitor transparent return shield preventing displaced apps from receiving the first click;
- per-monitor explicit-fullscreen suppression: immediate CENTER reset plus complete shell/gutter/shield unmap until fullscreen exits; the monitor-local QML shell and four gutter input surfaces are recreated on exit while C++ spatial state/controllers remain alive;
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
- event-driven plugin lifecycle safety: hot unload forces CENTER and hot reload re-handshakes/reacquires transform capability without polling;
- event-coalesced state refreshes;
- no compositor polling loop;
- unit tests for tokens, spatial state, responsive geometry, motion authority, Hyprland protocol parsing and compositor reset sequencing;
- GitHub-hosted Ubuntu 26.04 KVM/QEMU integration with guest DRM/KMS, seatd, Hyprland, the real Qt/Wayland shell and compositor plugin;
- deterministic Qt/Wayland integration client used to keep workspaces alive, request fullscreen and paint exact solid colors for pixel-level compositor validation;
- QEMU pixel-evidence probe using `grim` + Pillow to distinguish compositor render translation from logical window geometry for tiled, floating and pinned windows;
- QEMU native-workspace-animation characterization that proves the legacy `m_renderOffset` collision and independently verifies that the dedicated PSD presentation-offset POC can remain active while Hyprland's native workspace animation runs and settles;
- side-by-side screenshot evidence for legacy and dedicated transform backends before runtime migration.

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
- the live compositor lifecycle probe;
- a screenshot-based render-transform probe that measures actual client pixels before/after/reset while requiring `j/clients` geometry to remain unchanged.

The image URL is release-dated rather than `current`, and the harness verifies the cached/downloaded QCOW2 against Canonical's `SHA256SUMS` before booting it.

The VM validates compositor semantics, lifecycle and visible render translation. For the render proof it creates deterministic colored Wayland clients in tiled, floating and pinned states, applies an inward 96-logical-unit PSD render transform, captures the real output with `grim`, correlates the client-color mask with Pillow, and then verifies reset. It also requires Hyprland's logical client geometry to stay unchanged, proving that the experimental path is render-only rather than a window move.

The Hyprland 0.53.3 renderer already applies workspace `m_renderOffset` to non-pinned floating windows. PSD therefore does not add a second floating translation: it neutralizes Hyprland's workspace-animation-only floating correction to keep the movement rigid, and uses a per-window presentation offset only for pinned windows, which Hyprland explicitly excludes from workspace render offset. Native workspace-animation coexistence remains an unresolved experiment boundary.

It does **not** validate physical-device properties such as touchpad feel, NVIDIA-specific behavior, direct-scanout performance, VRR, real mixed-DPI displays or perceptual latency.

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
- verifies exactly one live `psd-shell:<output>` layer surface for every active Hyprland monitor; Hyprland `j/layers` entries with `pid=-1` are treated as closed/fading surfaces rather than active shell instances;
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
8. with `PSD_PROBE_EXERCISE_CRASH_RECOVERY=1`, kills `psd-shell` while that real displaced transform is still active, records whether the compositor retained a residual transform, restarts the shell, and requires every monitor to recover in clean CENTER with zero tracked transforms;
9. when the integration client is available, requests Hyprland fullscreen and requires PSD surfaces to unmap plus the compositor transform to reset;
10. requires fullscreen exit to recreate/remap a clean CENTER shell plus its four gutter input surfaces, verifies the compositor has removed the former fullscreen client, and then requires real gutter navigation to work again;
11. with `PSD_PROBE_EXERCISE_PLUGIN_LIFECYCLE=1`, displaces CENTER, unloads the compositor plugin, requires every shell instance to snap to clean CENTER, reloads the plugin and requires the real transform path to become usable again;
12. sends SIGTERM to the recovered shell and requires zero tracked transforms afterward;
13. restores the original workspace and cursor position.

With `PSD_PROBE_EXERCISE_HOTPLUG=1`, the same live shell also receives a temporary headless output. The probe requires its independent CENTER surface to appear, verifies the primary monitor is the only transformed output during navigation, and removes the temporary output again while the shell is still alive.

The QEMU CI enables the deterministic client, hotplug, SIGKILL-recovery and plugin hot unload/reload paths automatically. On arbitrary real hardware those paths remain opt-in so the probe does not create windows or virtual outputs unless explicitly requested.

GitHub-hosted CI also runs `tests/integration/test-probe-live-session-mock.sh`. That test uses a fake `hyprctl` and fake shell process only to validate the probe's control flow, cleanup ownership, CENTER-layer expectations and error handling. It is not compositor validation and does not replace the real-session probe.

This probe is the preferred entry point before declaring the current compositor experiment valid on real hardware.
