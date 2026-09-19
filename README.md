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

Early architecture, product-definition and prototype-validation phase.

The canonical specifications live under:

- `docs/` — human-readable product, architecture, design, automation, security, app and plugin documentation.
- `spec/` — versioned machine-readable contracts, schemas and design tokens.
- `prototypes/` — disposable validation prototypes; these are not production shell implementations.

Current design baselines:

- A — Product / UX Specification v0.1
- B — Spatial Glass Design System v0.1
- C — Automation / APIs / AI Integration v0.1

## Current prototype

`prototypes/spatial-shell-v0.3/` validates:

- persistent LEFT / RIGHT / TOP / DASH surfaces;
- rigid CENTER translation;
- edge dwell navigation;
- CENTER as a conventional desktop with icons and floating windows;
- direct CENTER -> DASH navigation;
- continuous Spatial Glass background without the hard gutter color seams from earlier experiments;
- runtime consumption of `spec/design-tokens.json` when served over HTTP.

From the repository root:

```bash
python3 -m http.server 8080
```

Then open:

```text
http://localhost:8080/prototypes/spatial-shell-v0.3/
```

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
