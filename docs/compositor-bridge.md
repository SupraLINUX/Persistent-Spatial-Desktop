# Compositor Bridge v0.1

Status: **implementation bootstrap**.

## Purpose

The compositor owns real Wayland application windows. PSD must observe compositor state without coupling the shell UI directly to Hyprland-specific JSON or socket details.

The runtime therefore uses an internal `CompositorBridge` abstraction.

Current backend:

- `HyprlandIpcBridge`

## Phase 1: read-only state bridge

The first implementation deliberately uses Hyprland's public UNIX IPC sockets rather than linking the shell against Hyprland internals.

Inputs:

- `$HYPRLAND_INSTANCE_SIGNATURE`
- `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock` for request/response state queries
- `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock` for live events

State currently normalized by PSD:

- monitors;
- workspaces;
- windows.

The shell does not expose raw Hyprland JSON as its internal model. `HyprlandProtocol` converts compositor-specific payloads to normalized maps first.

## Event model

The event socket remains connected and drives targeted state refreshes.

Examples:

- monitor events -> monitors + workspaces;
- workspace events -> monitors + workspaces;
- window events -> windows;
- config reload -> all state.

Refresh requests are coalesced with a short single-shot timer to avoid bursts of synchronous Hyprland info requests.

There is no periodic polling loop.

## Command-socket safety

Hyprland handles command-socket requests synchronously. PSD therefore:

- opens a transient socket only for a request;
- writes one JSON info request;
- parses the response;
- closes the connection immediately;
- enforces a one-second safety timeout.

This bridge currently issues only read-only information commands:

- `j/monitors`;
- `j/workspaces`;
- `j/clients`.

## Why no Hyprland build dependency yet

The shell can compile and run its core without Hyprland development headers. This avoids unnecessary ABI coupling during the state/introspection phase.

Ubuntu 26.04's Hyprland package is the runtime target for integration testing, not a compile-time dependency of `psd-core` at this stage.

## Phase 2: spatial transform

The public IPC state bridge is not expected to be sufficient for the defining PSD operation: transforming CENTER and compositor-owned windows as one coherent spatial unit.

That phase should use the narrowest compositor-side integration capable of:

- monitor-scoped spatial progress;
- coherent window/workspace transform;
- continuous gesture progress;
- snap/cancel;
- input/focus correctness;
- damage-driven rendering;
- fullscreen bypass;
- per-monitor independence.

The likely implementation is a PSD-specific Hyprland plugin/extension behind the same compositor abstraction.

Do not emulate the final spatial transform by repeatedly moving each client window through public dispatchers unless implementation evidence proves there is no better compositor-level path.
