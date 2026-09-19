# Product / UX Specification v0.1

Status: **baseline closed**  
Scope: product model and interaction semantics.

## 1. Product definition

Persistent Spatial Desktop (PSD) is a Wayland desktop environment built around a conventional Linux desktop placed at the center of a larger persistent spatial shell.

```
                    TOP
                     |
LEFT ------------- CENTER ------------- RIGHT
                     |
                    DASH
```

The shell follows one central rule:

> In the shell, nothing opens: the space moves.

This rule applies only to PSD spatial surfaces. Application windows remain normal Linux windows.

## 2. Spatial regions

### CENTER

CENTER is a real Linux desktop containing:

- static wallpaper;
- live/video wallpaper;
- desktop icons;
- files and folders;
- shortcuts;
- optional device icons;
- normal application windows.

CENTER is the user's spatial home. Sessions and crash recovery always begin in CENTER.

### LEFT

Primary purpose: find and open things.

- universal search;
- application launcher;
- files;
- favorites;
- recents.

### RIGHT

Primary purpose: control and intelligence.

- Wi-Fi;
- Bluetooth;
- audio;
- brightness and power;
- devices;
- clipboard;
- utilities;
- AI.

### TOP

Primary purpose: awareness and overview.

- overview;
- workspaces;
- windows;
- notifications;
- calendar;
- agenda.

### DASH

Primary purpose: application and task access.

- application search;
- app grid;
- dock;
- running applications;
- recents;
- media;
- tasks.

There is no intermediate BOTTOM surface.

## 3. Spatial movement

Spatial navigation is rigid translation.

During a spatial transition:

- CENTER is not scaled;
- windows are not resized;
- layout is not recomputed;
- relative distances do not change;
- the visible world translates as one coherent spatial system.

LEFT, RIGHT and TOP should leave a meaningful portion of CENTER visible. DASH may displace CENTER almost completely while preserving a small spatial reference if useful.

## 4. Mouse navigation

CENTER is surrounded by visible gutters that are part of the spatial world, not decorative borders.

Default interaction:

1. pointer enters a gutter;
2. a short dwell begins;
3. if the pointer leaves early, nothing happens;
4. if the dwell completes, navigation to that surface begins.

Initial default dwell: approximately **180 ms**.

The delay and enabled edges are configurable under Personalization / Spatial navigation.

During window move, resize, or drag-and-drop, normal gutter activation must not trigger accidentally.

## 5. Touchpad navigation

Touchpad spatial navigation is continuous and 1:1.

The visible translation follows gesture progress directly. On release, the shell uses distance and velocity to decide whether to:

- snap to the destination; or
- cancel and return.

Initial gesture preference:

- 3 fingers: conventional workspaces;
- 4 fingers: PSD spatial navigation.

Directional model:

- swipe right -> reveal LEFT;
- swipe left -> reveal RIGHT;
- swipe down -> reveal TOP;
- swipe up -> reveal DASH.

## 6. Keyboard navigation

PSD exposes abstract configurable actions:

- `spatial.left`
- `spatial.right`
- `spatial.top`
- `spatial.dash`
- `spatial.center`

Concrete default bindings are not yet frozen. Do not appropriate common bindings such as Super+Arrow without conflict analysis.

## 7. Input and focus

When a spatial surface is revealed:

- the revealed surface is fully interactive;
- CENTER remains visible where geometry allows;
- a click on visible CENTER first returns to CENTER;
- that first click is not forwarded to the displaced application beneath it.

Human input always has priority over shell choreography or automation.

## 8. Windows

Applications behave conventionally:

- open;
- close;
- move;
- resize;
- minimize;
- maximize;
- stack;
- focus.

PSD does not require applications to understand the spatial shell.

### Maximize

Maximize fills CENTER while preserving gutters and PSD navigation.

### Fullscreen

Explicit application fullscreen fills the physical monitor and temporarily hides PSD gutters/surfaces. No special PSD hot-zone is required.

## 9. Geometry

Geometry is based on logical units, proportions, and min/max clamps rather than physical-pixel constants.

Initial guidance:

- LEFT: ~24% width, min ~320, max ~460 logical units;
- RIGHT: ~26% width, min ~340, max ~500;
- TOP: ~25% height, min ~220, max ~320;
- gutter: approximately 12-18 adaptive logical units;
- DASH: near-full-height surface.

Exact values remain subject to prototype validation.

## 10. Workspaces

Conventional workspaces exist inside CENTER.

Spatial surfaces are not workspaces. LEFT, RIGHT, TOP and DASH remain shell infrastructure independent of the active workspace.

## 11. Multi-monitor

Each monitor owns its own spatial cross:

```
        TOP
         |
LEFT -- CENTER -- RIGHT
         |
        DASH
```

Navigating one monitor must not move the others.

## 12. Wallpaper

Wallpaper providers may support:

- image;
- slideshow;
- video;
- shader;
- future plugins.

Live wallpapers should use accelerated decoding/rendering where possible and suspend or reduce activity when hidden, on inactive monitors, or during fullscreen.

## 13. Compatibility principle

> Compatible by default. Native by choice.

Standard Linux applications should work unchanged. Native PSD applications may optionally use PSD.UI and semantic PSD APIs for deeper integration.
