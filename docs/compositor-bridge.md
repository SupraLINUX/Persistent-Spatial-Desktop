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

The state/introspection path issues read-only information commands:

- `j/monitors`;
- `j/workspaces`;
- `j/clients`.

## Why no Hyprland build dependency yet

The shell can compile and run its core without Hyprland development headers. This avoids unnecessary ABI coupling during the state/introspection phase.

Ubuntu 26.04's Hyprland package is the runtime target for integration testing, not a compile-time dependency of `psd-core` at this stage.

## Experimental plugin handshake

When the PSD Hyprland plugin is loaded, the bridge probes the custom `j/psd-plugin` command. The response declares a small versioned capability set rather than forcing the runtime to infer plugin availability.

The current experimental protocol is monitor-scoped and advertises:

- protocol version;
- plugin version;
- render-offset experiment support;
- explicit monitor targeting;
- opt-in four-finger gesture events;
- plugin lifecycle events required for safe hot unload/reload.

Without this handshake, compositor motion sync remains disabled. The current runtime also requires `lifecycleEventsExperimental=true`; an older experimental plugin that cannot announce unload/reload is intentionally treated as transform-incompatible.

The experimental plugin can emit `psdgesturebegin`, `psdgestureupdate`, and `psdgestureend` over Hyprland's existing event socket. The plugin does **not** intercept four-finger swipes merely because it is loaded: `plugin:psd:gesture-events 1` must be explicitly enabled. Three-finger gestures remain untouched.

The same event socket carries `psdpluginready` and `psdpluginunloading`. These are lifecycle safety events, not public PSD API. On unload, the bridge invalidates transform capabilities immediately and every enabled monitor-local sync snaps its visual motion to CENTER while the plugin resets all touched workspaces. On reload, the ready event triggers a fresh capability handshake. A failed transform command also refreshes capabilities as a fallback if lifecycle delivery races the command.

### Experimental diagnostic state

The plugin also registers `j/psd-plugin-state` for integration diagnostics. This is **not** a public PSD API and does not change the protocol-v3 capability contract.

The JSON response exposes only experiment-owned state needed by probes:

- currently tracked monitor transforms;
- the last requested x/y offset for each tracked monitor;
- an opaque monotonically increasing workspace-generation value;
- the count of previous-workspace resets caused by retargeting;
- touched-workspace count;
- gesture arm/active state.

The workspace generation is intentionally opaque. It exists so a live integration probe can prove that a non-zero transform was retargeted to a different workspace without exposing Hyprland workspace internals as a PSD contract.

## Phase 2: spatial transform

The public IPC state bridge is not expected to be sufficient for the defining PSD operation: transforming CENTER and compositor-owned windows as one coherent spatial unit.

The runtime-side gesture contract now exists independently of Hyprland. `SpatialMotionController` accepts logical-unit begin/update/end input, tracks translation 1:1, locks to a spatial axis, and settles by distance or release velocity. The compositor backend is responsible only for feeding correctly scaled global gesture deltas and release velocity.

That phase should use the narrowest compositor-side integration capable of:

- monitor-scoped spatial progress;
- coherent window/workspace transform;
- continuous gesture progress;
- snap/cancel;
- input/focus correctness;
- damage-driven rendering;
- fullscreen bypass;
- per-monitor independence.

A PSD-specific Hyprland plugin now exists as an experiment behind the same compositor abstraction. Inspection of the exact Ubuntu 26.04 target source (Hyprland 0.53.3) established the renderer semantics before further modification:

- `CHyprRenderer::renderWindow()` adds `CWorkspace::m_renderOffset` to every **non-pinned** window, including floating windows;
- Hyprland's workspace-animation update callback separately rewrites `CWindow::m_floatingOffset` for floating-window edge/clipping correction;
- pinned windows are deliberately excluded from workspace `m_renderOffset`.

An earlier PSD experiment incorrectly added the PSD vector to `m_floatingOffset` for all floating windows. The QEMU diagnostic exposed the collision (`applied=-96`, Hyprland correction present at the same time), so that approach was rejected.

The corrected experiment uses workspace `m_renderOffset` as the sole translation for tiled and non-pinned floating content. Immediately after Hyprland's synchronous workspace-offset callback, PSD neutralizes the workspace-animation-only `m_floatingOffset` correction on non-pinned floating windows to preserve rigid translation. Pinned windows receive the PSD vector through `m_floatingOffset` because the renderer intentionally excludes them from `m_renderOffset`. Reset, workspace retarget and plugin unload return those presentation offsets to zero.

This remains a proof of concept, not an accepted production mechanism. `m_renderOffset` is itself owned by Hyprland's native workspace-animation system, so coexistence with animated workspace changes is a known unresolved coupling and must be validated or replaced with a dedicated compositor-side PSD transform before production adoption. The screenshot probe remains authoritative: tiled, floating and pinned pixels must translate while `j/clients` logical geometry remains unchanged.

The internal transform command contract is now also compositor-generic: `SpatialCompositorSync` talks to `CompositorBridge`, not directly to `HyprlandIpcBridge`. Each transform command receives an internal command ID so completion from an unrelated or stale request cannot accidentally release another monitor-local command queue.

### Transform lifecycle safety

A monitor-local transform sync permits at most one compositor command in flight. Intermediate animation/gesture offsets are coalesced to the latest pending value.

Disabling the sync does not send a reset in parallel with an existing offset. Instead it:

1. stops accepting new pending offsets;
2. waits for the identified in-flight command to complete;
3. sends a final reset;
4. considers the monitor settled only after that reset is confirmed.

Normal shell shutdown uses the same lifecycle with a bounded drain period. SIGTERM/SIGINT are converted into an orderly Qt shutdown so the reset path can run before process exit.

The Hyprland plugin also tracks the exact workspace transformed by PSD for each monitor. `plugin:psd:reset <monitor>` resets that tracked workspace rather than whichever workspace happens to be active when the reset arrives. When the compositor reports a changed active workspace while PSD is displaced, the runtime replays the current non-zero transform; the plugin first resets the previously tracked workspace and then adopts the new active workspace. Plugin unload still resets every workspace touched by the experiment.

These safeguards reduce residual-offset risk during normal shutdown, workspace changes, monitor teardown and plugin hot unload/reload. QEMU integration also verifies that SIGKILL can leave a residual transform but a subsequent shell start clears it back to CENTER. A compositor crash or machine loss still cannot execute cleanup and remains a separate recovery boundary.

Do not emulate the final spatial transform by repeatedly moving each client window through public dispatchers unless implementation evidence proves there is no better compositor-level path.
