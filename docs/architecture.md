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
- PSD-owned runtime;
- C++ for deep Qt/system/compositor integration where justified;
- Hyprland as the initial compositor base.

Quickshell is a useful implementation reference, not a required architectural dependency.

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

The compositor owns real application windows. The PSD shell owns spatial surfaces, desktop UI, shared shell state and system integration.

The spatial bridge must expose a coherent workspace/surface transform. Avoid implementing the effect by moving every application window independently if the compositor can expose a lower-level transformation.

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
