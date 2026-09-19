# Hyprland workspace-offset proof of concept

Status: **experiment** — not an accepted production mechanism.

## Question

Can PSD move the visible CENTER workspace, including normal compositor-owned application windows, as one render-space unit without issuing one move command per client?

## Candidate

Hyprland 0.53.3 exposes `CWorkspace::m_renderOffset`, an animated `Vector2D` used by its own workspace animation and gesture code.

The renderer adds this offset to workspace window render positions. Hyprland's workspace swipe code updates it continuously with `setValueAndWarp()`.

This makes it a useful low-level proof-of-concept target for PSD.

## Experimental plugin

The optional build target `psd-hyprland-plugin` registers three internal dispatchers:

- `plugin:psd:offset <monitor> <x> <y>`
- `plugin:psd:reset <monitor>`
- `plugin:psd:gesture-events <0|1>`

The offset command applies a render offset to the active regular workspace of the explicitly named monitor and damages only that monitor.

The experiment refuses non-zero offsets for:

- missing monitor/workspace;
- special workspaces;
- workspaces containing fullscreen content.

A zero reset through `plugin:psd:reset` remains allowed in fullscreen. This is required so entering fullscreen can never strand a previous spatial render offset.

Plugin unload resets every workspace touched by this experiment. Four-finger gesture interception is disabled by default and must be explicitly armed.

## Build

The plugin is intentionally opt-in because Hyprland plugins are ABI-sensitive.

```bash
sudo apt install hyprland-dev pkgconf libgles-dev
cmake -S . -B build-hypr -G Ninja \
  -DPSD_BUILD_SHELL=OFF \
  -DPSD_BUILD_HYPRLAND_PLUGIN=ON \
  -DBUILD_TESTING=OFF
cmake --build build-hypr --target psd-hyprland-plugin
```

Output:

```text
build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so
```

## Manual experiment

Only run this inside the matching Hyprland build/session.

After loading the plugin, examples are:

```bash
hyprctl dispatch plugin:psd:offset 'DP-1 160 0'
hyprctl dispatch plugin:psd:offset 'DP-1 0 120'
hyprctl dispatch plugin:psd:reset 'DP-1'
hyprctl dispatch plugin:psd:gesture-events 1
# test the four-finger feed
hyprctl dispatch plugin:psd:gesture-events 0
```

## Runtime-driven experiment

When the shell is started with:

```bash
PSD_EXPERIMENTAL_HYPRLAND_SYNC=1 ./build/psd-shell
```

each monitor-local `SpatialMotionController` may stream its current render offset to the matching Hyprland output, but only when the PSD plugin capability handshake succeeds.

The bridge applies backpressure: there is at most one command in flight per monitor and intermediate offsets are coalesced to the latest value. No polling is introduced.

This mode is intentionally opt-in until input/hit-testing and compositor behavior are validated.

## Input finding

Hyprland 0.53.3 does not include `CWorkspace::m_renderOffset` in its normal window hit-test geometry. `CWindow::getWindowBoxUnified()` is based on the window's logical/real position and size, and `CCompositor::vectorToWindowUnified()` uses that geometry for pointer targeting.

That means the experiment is a render transform, not an input transform.

PSD's closed UX contract does not require displaced application windows to remain directly clickable: while a spatial surface is revealed, clicking the still-visible part of CENTER must first return to CENTER and must not be forwarded to the application below.

The bootstrap therefore uses a transparent per-monitor LayerTop return shield:

- full-monitor while a spatial transition is running;
- restricted to only the visible CENTER region after LEFT/RIGHT/TOP/DASH settles;
- hidden in CENTER;
- keyboard non-interactive;
- first pointer press is consumed and triggers `spatial.center`.

This preserves the product input rule without adding invasive Hyprland input hooks. The revealed PSD surface remains outside the shield and stays interactive.

## What success proves

Success proves only that Hyprland can render the current workspace's normal windows at a PSD-controlled offset as a coherent unit.

## What it does NOT prove

It does not yet prove:

- pointer/touch hit testing follows the visual offset;
- keyboard focus behavior is correct;
- popups/subsurfaces behave correctly;
- layer-shell PSD surfaces compose correctly with the shifted workspace;
- pinned windows should move or stay fixed;
- continuous four-finger gesture latency is acceptable;
- multi-monitor isolation is correct;
- fullscreen shell unmap/remap and direct-scanout behavior are correct on real hardware;
- damage remains minimal under all cases.

Those questions must be tested before adopting `m_renderOffset` as the production transform mechanism.

## Production rule

Do not build public PSD APIs around this Hyprland internal member. The shell talks to a PSD compositor abstraction; Hyprland internals remain isolated in the backend/plugin.
