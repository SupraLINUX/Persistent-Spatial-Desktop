# ADR 0008 — Separate spatial render translation from application input

Status: Accepted  
Baseline: v0.1

## Context

The current Hyprland proof of concept uses `CWorkspace::m_renderOffset` to translate the active workspace as a coherent rendered unit.

Hyprland 0.53.3 window hit testing remains based on the window's logical/real geometry rather than that render offset. Making displaced application windows directly interactive would therefore require deeper compositor input changes.

PSD Product/UX v0.1 already defines a different interaction: while a spatial surface is revealed, the visible remainder of CENTER is not directly interactive. The first click on it returns to CENTER and is not forwarded to the application underneath.

## Decision

Do not modify Hyprland hit testing merely to make displaced application windows clickable.

Each monitor owns a transparent return-shield layer surface:

- hidden while the monitor is in CENTER;
- full-monitor while spatial motion is in progress;
- after settling, limited to the portion of CENTER that remains visible;
- placed on LayerTop;
- keyboard interactivity disabled;
- pointer press consumed and translated into a request to return to CENTER.

The revealed LEFT/RIGHT/TOP/DASH area is left outside the shield and remains interactive.

## Consequences

- product input semantics are explicit rather than accidental;
- applications cannot receive destructive clicks while visually displaced;
- the compositor plugin can remain narrowly focused on rendering for this experiment;
- input and focus correctness still require real-session validation;
- fullscreen bypass and pinned-window behavior remain separate validation items.

## Revisit condition

Revisit only if a future UX decision requires direct interaction with displaced application windows, or if a compositor-native spatial primitive provides render and hit-test transforms together without invasive hooks.
