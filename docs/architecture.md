# Architecture v0.1

Status: **baseline architecture direction**.

## Goals

PSD must be:

- Wayland-only;
- modular without excessive process fragmentation;
- efficient at idle;
- safe to install alongside Ubuntu;
- extensible through versioned APIs;
- introspectable and automatable;
- suitable for native Qt/QML applications.

## Platform

Development baseline:

- Ubuntu 26.04;
- Qt 6;
- Qt Quick/QML;
- LayerShellQt as the narrow Qt adapter for the Wayland `wlr-layer-shell` protocol;
- PSD-owned runtime;
- C++ for deep Qt/system/compositor integration where justified;
- Hyprland as the initial compositor base.

Quickshell is a useful implementation reference, not a required architectural dependency.

LayerShellQt is accepted only as a small protocol adapter. PSD still owns its runtime, QML tree, state, APIs and compositor integration. Using the packaged adapter avoids embedding QtWayland private API code in PSD.

Hyprland may be reconsidered only if real implementation work demonstrates a concrete blocker.

## Sessions

Expected Wayland sessions:

- Persistent Spatial Desktop;
- Persistent Spatial Desktop — Safe Mode;
- GNOME Wayland as an optional external recovery environment.

No Xorg fallback is part of the design.

Safe Mode uses the same PSD codebase with a conservative configuration:

- official essential modules only;
- known-good defaults;
- third-party plugins disabled;
- external overrides/themes/scripts disabled;
- live wallpaper may be disabled.

## High-level decomposition

```
Applications
    |
Wayland surfaces
    |
Compositor (initially Hyprland)
    |
PSD spatial compositor bridge
    |
PSD Runtime (Qt 6 / C++ / QML)
    |
+-----------------------------+
| shared state / registries   |
+-----------------------------+
 |      |      |      |      |
Desktop LEFT   RIGHT  TOP    DASH
```

The compositor owns real application windows. The PSD shell owns spatial surfaces, desktop UI, shared shell services and system integration.

The runtime creates one independent layer-shell window per `QScreen`. Each monitor instance owns its own `SpatialState`, `SpatialLayout` and `SpatialMotionController`, while global services such as design tokens and compositor introspection remain shared. This preserves the product rule that navigating one monitor must not move the others.

The spatial bridge must expose a coherent workspace/surface transform. Avoid implementing the effect by moving every application window independently if the compositor can expose a lower-level transformation.

Input is intentionally separated from render translation. During a spatial transition, a monitor-local transparent LayerTop shield consumes pointer presses so displaced applications cannot receive accidental input. After the transition settles, the shield covers only the still-visible CENTER area; the revealed PSD surface remains interactive. In CENTER the shield is unmapped.

## Compositor bridge layers

The compositor integration is split intentionally.

### State/introspection layer

Current implementation:

- generic internal `CompositorBridge`;
- `HyprlandIpcBridge` backend;
- public Hyprland IPC sockets only;
- normalized monitors/workspaces/windows;
- event-driven updates through Hyprland's event socket;
- no periodic polling;
- no compile-time dependency on Hyprland headers.

This layer is read-only during the bootstrap phase.

### Spatial-transform layer

The defining PSD spatial transform requires compositor-side cooperation. It should provide monitor-scoped continuous translation for CENTER and compositor-owned application windows while preserving input, focus, fullscreen semantics and damage tracking.

The expected implementation is a narrow PSD-specific Hyprland plugin/extension behind the compositor abstraction.

Do not implement the final effect by repeatedly dispatching per-window move commands unless a prototype demonstrates that compositor-level transformation is impossible.

See `docs/compositor-bridge.md`.

## Runtime modularity

Prefer one main Qt/QML runtime with modular components and shared state.

Initial provider/module concepts:

- Desktop;
- Wallpaper;
- DesktopIcons;
- Search;
- Launcher;
- Notifications;
- Control;
- AI;
- Surface;
- PluginRegistry;
- Automation.

A module should depend on stable interfaces rather than concrete implementations.

## Plugins

Visual plugins should primarily use restricted QML APIs and explicit extension points.

Third-party native code should preferably run out of process and communicate through IPC.

Plugin contracts require:

- API version;
- manifest;
- capabilities/permissions;
- configuration schema;
- compatibility declaration;
- failure handling.

## Ubuntu safety

PSD must not require destructive replacement of Ubuntu base libraries.

Avoid:

- manually replacing files in `/usr/lib`;
- invasive PPAs replacing major Qt/system stacks;
- coupling PSD to a modified GNOME installation;
- making PSD the only recoverable graphical session during development.

Packaging should eventually allow clean installation and removal.

## Rendering and performance

Architecture must be event-driven and damage-driven.

Targets:

- shell idle CPU approximately 0%;
- no continuous redraw without visual damage;
- avoid polling when system events exist;
- desirable core+shell RAM ~150-200 MiB;
- initial upper target <250 MiB;
- no Electron/WebView in core without exceptional justification.

Prefer signals/events from:

- Qt;
- compositor;
- D-Bus;
- NetworkManager;
- PipeWire;
- UPower;
- inotify or equivalent filesystem notification.

Persistent means state is retained, not that work runs continuously.

## Native application stack

PSD-native applications should be able to use the same Qt 6/QML design system as the shell through PSD.UI.

Complex apps may combine:

- QML UI;
- C++ or another appropriate native backend;
- semantic PSD APIs.

External Linux apps remain supported without PSD-specific code.
