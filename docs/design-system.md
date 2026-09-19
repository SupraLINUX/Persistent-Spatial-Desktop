# Spatial Glass Design System v0.1

Status: **baseline closed**.

Design name: **Spatial Glass**  
Principle: **Depth without clutter.**

## Character

PSD is dark-first, restrained and spatial.

Desired qualities:

- deep;
- clean;
- soft;
- moderately translucent;
- visually layered;
- calm rather than flashy.

Avoid:

- cyberpunk styling;
- gamer RGB;
- direct macOS imitation;
- Material clone;
- Breeze clone;
- excessive glassmorphism.

## Continuous spatial background

All shell regions share one visual world.

```
SpatialBackground
├── LEFT
├── RIGHT
├── TOP
├── DASH
└── CENTER
```

Gutters do not use an unrelated solid color. They should visually continue the wallpaper/tint/material behind CENTER so the desktop appears suspended over a larger environment.

## Base palette

- Deep Background: `#0C1018`
- Dark Navy: `#11192D`
- Spatial Blue: `#25355F`
- Deep Violet: `#302744`
- Depth Violet: `#25203B`
- Primary accent: `#A9B7FF`
- Secondary accent: `#8E7CFF`
- Primary text: `#F6F7FB`
- Secondary text: `rgba(246,247,251,0.68)`
- Muted text: `rgba(246,247,251,0.48)`
- Disabled text: `rgba(246,247,251,0.30)`

Accent is used sparingly for focus, selection, progress and meaningful active state.

## Materials

### Surface.Solid

Near-opaque surface for maximum legibility.

### Surface.Glass

Primary PSD material:

- dark;
- approximately 75-85% opacity;
- moderate blur;
- subtle border.

### Surface.Subtle

Internal cards/subdivisions, typically around 5-8% white contribution over the parent.

### Surface.Floating

Menus/popovers with additional contrast and elevation.

## Blur

Blur is selective, not global.

Typical use:

- shell surfaces;
- launcher;
- DASH;
- control center;
- floating shell UI;
- PSD titlebars when appropriate.

Initial reference: approximately 20-24 logical units.

Modes should include Off, Reduced and Standard.

## Geometry

Initial radius tokens:

- workspace: 24;
- window: 18;
- large panel: 20;
- card: 16;
- input: 14;
- small control: 12.

## Borders

Typical border:

- width: 1 logical unit;
- default: rgba(255,255,255,0.10);
- focused: rgba(255,255,255,0.16);
- unfocused: rgba(255,255,255,0.08).

Avoid bright thick outlines.

## Shadows

Windows:

- vertical offset ~20-24;
- blur ~50-60;
- opacity ~30-36%.

Workspace:

- deeper shadow;
- blur ~80-90.

Popovers:

- smaller elevation;
- blur ~32.

## PSD windows

Native PSD application windows use:

- dark glass treatment;
- rounded outer geometry;
- restrained titlebar;
- subtle divider;
- clear focus state.

Initial titlebar height: ~42 logical units.

Window controls remain visually neutral by default. Do not copy macOS traffic-light colors.

External application decorations are harmonized only through robust compositor/toolkit mechanisms. Do not rely on fragile per-application hacks.

## Typography

Preferred: Inter Variable.

Fallback:

- Noto Sans;
- Ubuntu Sans;
- system-ui.

Approximate scale:

- Display: 30-34;
- Title: 22-24;
- Heading: 16-18;
- Body: 14;
- Secondary: 12-13;
- Caption: 11.

## Spacing

Canonical scale:

- xs: 4;
- sm: 8;
- md: 12;
- lg: 16;
- xl: 24;
- 2xl: 32;
- 3xl: 48.

## Motion

Spatial mouse transition:

- approximately 450-520 ms;
- reference easing: `cubic-bezier(.22,.85,.26,1)`.

Touchpad movement is 1:1 while fingers are down.

Snap after release:

- approximately 180-260 ms.

Micro-interactions:

- hover ~120 ms;
- control state ~120-160 ms;
- popover ~160-200 ms;
- native window open ~180-220 ms.

Avoid exaggerated bounce.

## Region layout guidance

LEFT prioritizes:

1. Search
2. Apps
3. Files / Recent

RIGHT uses a clear hierarchy for system controls, AI and utilities rather than an undifferentiated card wall.

TOP takes advantage of horizontal width, initially favoring columns for notifications, calendar and workspace/overview information.

DASH uses generous spacing for application search, application grid, dock, running apps, recents, media and tasks.

No permanent dock is required in CENTER for v0.1.

## Dynamic color

PSD may derive a safe accent/tint from wallpaper. Contrast must be validated; invalid results fall back to the canonical lavender-blue accent.

## Accessibility

Design from v0.1 for:

- Reduce Motion;
- Reduce Transparency;
- High Contrast;
- Text Scaling;
- Animation Speed.

## PSD.UI

The design system should become a real reusable QML library, not only documentation.

Conceptual namespaces:

- Foundations;
- Controls;
- Surfaces;
- Navigation;
- Window.

Machine-readable tokens live in `spec/design-tokens.json`.
