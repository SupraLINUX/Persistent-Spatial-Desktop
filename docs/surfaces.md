# Spatial Surfaces v0.1

Status: **baseline closed**.

PSD has five primary spatial regions:

```
                    TOP
                     |
LEFT ------------- CENTER ------------- RIGHT
                     |
                    DASH
```

## CENTER

A conventional desktop surface containing wallpaper, desktop items and normal application windows.

CENTER is always the starting region.

## LEFT

Purpose: discovery and opening.

Typical content:

- universal search;
- launcher;
- files;
- favorites;
- recents.

## RIGHT

Purpose: control and intelligence.

Typical content:

- system toggles;
- devices;
- audio/brightness/power;
- clipboard;
- AI;
- utilities.

## TOP

Purpose: awareness.

Typical content:

- overview;
- workspaces/windows;
- notifications;
- calendar;
- agenda.

## DASH

Purpose: application/task access.

Typical content:

- search;
- application grid;
- dock;
- running apps;
- recents;
- media;
- tasks.

## Persistence

Surfaces retain internal state while not visible.

Examples:

- search query;
- scroll position;
- selected section;
- media state;
- AI conversation state.

The current spatial position itself is ephemeral and resets to CENTER on a new session.

## Gutter

The gutter is the visible spatial seam around CENTER.

It is:

- visual evidence that space exists beyond CENTER;
- part of the continuous spatial background;
- an input activation zone.

It is not a conventional panel or decorative border.

## Multi-monitor

Each monitor owns its own CENTER and four surrounding surfaces. Spatial navigation on one monitor does not automatically affect another.
