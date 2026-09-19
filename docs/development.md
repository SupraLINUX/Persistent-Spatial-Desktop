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
- Wayland `wlr-layer-shell` surface through LayerShellQt;
- QML shell root;
- persistent CENTER/LEFT/RIGHT/TOP/DASH object structure;
- mouse gutter dwell navigation;
- rigid translation between shell surfaces driven by a single C++ motion controller;
- CENTER return semantics;
- generic internal compositor bridge abstraction;
- Hyprland IPC state backend;
- monitor/workspace/window normalization;
- live event socket;
- event-coalesced state refreshes;
- no compositor polling loop;
- unit tests for tokens, spatial state and Hyprland protocol parsing.

## Current compositor boundary

The Hyprland IPC bridge is intentionally read-only.

It currently issues:

- `j/monitors`;
- `j/workspaces`;
- `j/clients`.

The next compositor milestone is not more shell mock UI. It is a compositor-side spatial-transform proof of concept capable of moving CENTER and real client windows coherently on one monitor.

See `docs/compositor-bridge.md`.

## What is not implemented yet

- production login/session entry;
- compositor-level spatial transform;
- production adoption of the experimental Hyprland render-offset mechanism;
- real desktop icons/files;
- notifications/control center/search providers;
- touchpad 1:1 spatial gestures;
- public D-Bus/IPC automation.

Those are subsequent implementation milestones and must use the versioned contracts in `docs/` and `spec/`.
