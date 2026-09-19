# Development bootstrap

PSD currently has a minimal real Qt 6/QML runtime. It is not yet a complete desktop session and does not yet move compositor-owned application windows.

## Baseline

- Ubuntu 26.04
- Qt 6.10 or newer within the Qt 6 series
- C++20
- CMake
- Ninja

## Ubuntu 26.04 dependencies

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build qt6-base-dev qt6-declarative-dev
```

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

The current executable validates the first production architecture pieces:

- Qt 6 application/runtime startup;
- embedded canonical Spatial Glass design-token loading;
- shared C++ spatial state;
- QML shell root;
- persistent CENTER/LEFT/RIGHT/TOP/DASH object structure;
- mouse gutter dwell navigation;
- rigid translation between surfaces;
- CENTER return semantics at shell level;
- unit tests for tokens and spatial-state validity.

## What this does not implement yet

- a login/session entry;
- Hyprland integration;
- compositor-level translation of real application windows;
- real desktop icons/files;
- notifications/control center/search providers;
- touchpad 1:1 gestures;
- public D-Bus/IPC automation.

Those are subsequent implementation milestones and must use the versioned contracts in `docs/` and `spec/`.
