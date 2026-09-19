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

Early architecture and product-definition phase.

The canonical specifications live under:

- `docs/` — human-readable product, architecture, design, automation, security, app and plugin documentation.
- `spec/` — versioned machine-readable contracts, schemas and design tokens.

Current design baselines:

- A — Product / UX Specification v0.1
- B — Spatial Glass Design System v0.1
- C — Automation / APIs / AI Integration v0.1

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
