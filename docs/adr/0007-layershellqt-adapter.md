# ADR 0007 — LayerShellQt as the shell-surface protocol adapter

Status: Accepted  
Baseline: v0.1

## Context

PSD shell surfaces must not be ordinary XDG application windows. They need monitor-anchored Wayland shell semantics so compositor-owned application windows can move independently from the persistent PSD surfaces.

Implementing `wlr-layer-shell` directly through Qt would require PSD to depend on QtWayland private APIs or maintain its own shell-integration plugin.

Ubuntu 26.04 already packages the Qt 6 LayerShellQt interface.

## Decision

Use LayerShellQt as a narrow adapter for `wlr-layer-shell`.

PSD itself continues to own:

- runtime lifecycle;
- QML shell UI;
- spatial state and motion;
- compositor bridge;
- plugin model;
- public APIs;
- design system.

LayerShellQt is not the desktop framework and does not determine PSD architecture.

## Current surface policy

The bootstrap shell maps as:

- layer: Background;
- anchored to all four monitor edges;
- exclusive zone: -1;
- keyboard interactivity: OnDemand;
- scope: `psd-shell:<output-name>`.

This lets the persistent shell occupy the full monitor without reserving panel space while ordinary application windows remain compositor-owned above it.

## Consequences

- PSD avoids maintaining QtWayland-private integration code;
- the runtime gains a small packaged dependency;
- shell surfaces can remain stationary while the compositor plugin experiments with workspace render offsets;
- the runtime instantiates one shell layer surface per Qt/Wayland output and keeps spatial state independent per monitor.

## Revisit condition

Replace LayerShellQt only if it blocks required input, multi-monitor, performance or protocol behavior, or if its packaging becomes unsuitable for the supported Ubuntu base.
