# Development bootstrap

PSD currently has a minimal real Qt 6/QML runtime plus the first Hyprland compositor-state bridge. It is not yet a complete desktop session and does not yet transform compositor-owned application windows.

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
- rigid translation between shell surfaces driven by a single C++ motion controller;
- CENTER return semantics;
- per-monitor transparent return shield preventing displaced apps from receiving the first click;
- generic internal compositor bridge abstraction;
- Hyprland IPC state backend;
- monitor/workspace/window normalization;
- live event socket;
- event-coalesced state refreshes;
- no compositor polling loop;
- unit tests for tokens, spatial state, responsive geometry, motion authority and Hyprland protocol parsing.

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
- touchpad 1:1 spatial gestures;
- public D-Bus/IPC automation.

Those are subsequent implementation milestones and must use the versioned contracts in `docs/` and `spec/`.

## Headless compositor integration probe

`tests/integration/probe-hyprland-plugin.sh` can launch Hyprland with its headless output backend, load the PSD plugin, validate the JSON capability handshake, and exercise monitor-scoped offset/reset.

Run it on a Linux machine with a DRM render node:

```bash
sudo apt install hyprland python3
bash tests/integration/probe-hyprland-plugin.sh
```

The probe is intentionally not part of GitHub-hosted CI. Hyprland 0.53.3 uses Aquamarine 0.10, whose backend startup requires a DRM-backed allocator even for the headless output backend. Standard hosted GitHub containers do not expose `/dev/dri/renderD*`, so Hyprland aborts before its IPC sockets are created.

This is an infrastructure limitation, not a plugin compile failure. The normal Ubuntu 26.04 CI still compiles both the shell and the ABI-sensitive plugin on every PR.
