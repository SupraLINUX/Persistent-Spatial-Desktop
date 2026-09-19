# Persistent Spatial Desktop

Persistent Spatial Desktop (PSD) is a modular Wayland desktop environment focused on a persistent spatial shell model.

```
                    TOP
                     |
LEFT ------------- CENTER ------------- RIGHT
                     |
                    DASH
```

CENTER is a conventional Linux desktop with wallpaper/live wallpaper, desktop icons, files/folders, and normal application windows. LEFT, RIGHT, TOP, and DASH are persistent spatial surfaces revealed by translating the desktop space rather than opening overlay panels.

## Status

Implementation bootstrap.

The repository now contains:

- `docs/` — human-readable product, architecture, design, automation, security, app and plugin documentation.
- `spec/` — versioned machine-readable contracts, schemas and Spatial Glass design tokens.
- `src/` — C++ runtime/core implementation.
- `qml/` — Qt Quick shell UI.
- `tests/` — core tests.

Current design baselines:

- A — Product / UX Specification v0.1
- B — Spatial Glass Design System v0.1
- C — Automation / APIs / AI Integration v0.1

## Current implementation

The first real `psd-shell` runtime is being built directly with Qt 6, Qt Quick/QML and C++.

Implemented in the bootstrap:

- Qt application/runtime entry point;
- canonical `spec/design-tokens.json` loaded as an embedded runtime resource;
- shared C++ `SpatialState`;
- QML CENTER / LEFT / RIGHT / TOP / DASH object structure;
- rigid spatial translation;
- ~180 ms mouse gutter dwell;
- CENTER return semantics at shell level;
- core unit tests;
- Ubuntu 26.04 CI build environment.

This is not yet a complete desktop session. Real compositor-owned application windows and Hyprland integration are subsequent milestones.

See `docs/development.md` for build instructions and the exact current boundary.

## Development target

- Ubuntu 26.04
- Wayland only
- Qt 6 + Qt Quick/QML
- PSD-owned runtime
- Hyprland as the initial compositor base, subject to revision only if implementation reveals concrete limitations

## Core principles

- Spatial, not overlayed.
- Compatible by default. Native by choice.
- Persistent state, idle computation.
- Human-readable and machine-readable by design.
- Everything meaningful should be addressable semantically.
- Semantic execution, optional visual choreography.
- Human input always has priority over automation.

## License

License has not been selected yet.
