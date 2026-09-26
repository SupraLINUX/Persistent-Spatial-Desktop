# ADR 0006 — Hyprland IPC first for compositor state

Status: Accepted  
Baseline: v0.1

## Decision

Use Hyprland's public UNIX IPC sockets for the first compositor integration layer that observes monitors, workspaces, windows and live compositor events.

Keep this read-only state bridge separate from the future compositor-side spatial-transform implementation.

## Rationale

- no Hyprland ABI dependency is needed for shell state discovery;
- the event socket provides event-driven updates without polling;
- normalized PSD state prevents QML/modules from depending directly on Hyprland JSON;
- the architecture remains replaceable if the compositor backend changes later;
- plugin complexity is deferred until a capability actually requires compositor internals.

## Constraint

This decision does not imply that public IPC is suitable for the final spatial transform.

The transform that moves CENTER and real application windows as one unit should be implemented at compositor level rather than by issuing per-window move commands.
