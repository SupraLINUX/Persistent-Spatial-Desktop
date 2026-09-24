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

The event socket remains connected and drives targeted state refreshes. Fullscreen state is reconciled from both the active workspace aggregate (`j/workspaces.hasfullscreen`) and client fullscreen mode (`j/clients.fullscreen`). Hyprland 0.53.3 updates both internal fullscreen state representations before emitting `fullscreen`, so PSD performs one coalesced windows+workspaces refresh per event without polling or delayed retries.

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


### Native workspace-animation coexistence characterization

Hyprland 0.53.3's native workspace transition implementation owns the same
`CWorkspace::m_renderOffset` animated variable used by the current PSD proof of
concept. The QEMU integration suite therefore contains a dedicated
`probe-vm-workspace-animation.sh` characterization test.

The probe first enables a deliberately observable native slide transition and
requires the active workspace's `m_renderOffset` to enter and leave
`isBeingAnimated()` normally. It then establishes a PSD offset, triggers
another native workspace transition, and immediately sends the PSD offset to
the incoming workspace. The plugin records the value/goal it observed *before*
the PSD write.

At this stage the test is intentionally a characterization test: it succeeds
when the shared-variable collision is demonstrated. A confirmed collision means
the current `m_renderOffset` proof of concept cannot be considered a
production-safe coexistence mechanism for simultaneous PSD displacement and
native Hyprland workspace animation. The eventual runtime policy must either
serialize/cancel one motion domain or move PSD to a dedicated compositor-side
transform that does not reuse Hyprland's workspace-animation variable.


### Dedicated PSD presentation-offset POC

A second experimental transform backend is now implemented side-by-side with
the legacy `m_renderOffset` proof of concept. It does **not** replace the
runtime contract yet.

On Hyprland 0.53.3 the plugin resolves and hooks
`CHyprRenderer::renderWindow()` through Hyprland's function-hook API. PSD owns
a monitor-scoped `Vector2D` offset. During a normal window render call, the
hook temporarily composes that vector with Hyprland's already-computed
`CWindow::m_floatingOffset`, invokes the original renderer, and immediately
restores the native value.

Consequences of the experiment:

- PSD no longer writes `CWorkspace::m_renderOffset` in the dedicated path;
- Hyprland retains ownership of workspace animations;
- Hyprland's existing floating correction is preserved and composed rather than
  neutralized;
- tiled, floating and pinned windows share the same monitor-scoped PSD vector;
- popup/subsurface inheritance is **not** assumed from call structure alone;
  each must pass an explicit protocol-aware pixel probe before this backend is
  promoted;
- logical client geometry remains untouched;
- layer-shell PSD surfaces are not transformed by this hook.

The hook is intentionally marked experimental. Hyprland explicitly states that
internal function hooks have no API-stability guarantee. The production goal is
to validate the transform semantics with this POC, then either use a stable
upstream extension point when available or propose a small generic presentation
transform extension upstream.

The dedicated backend uses separate experimental dispatchers:

- `plugin:psd:presentation-offset <monitor> <x> <y>`;
- `plugin:psd:presentation-reset <monitor>`.

The legacy commands remain available only as a comparison baseline until the
dedicated backend passes the complete validation suite and the runtime is
migrated.


### Modern Hyprland comparison checkpoint — v0.56.2

The stable upstream comparison target is pinned to **Hyprland v0.56.2** rather
than `main`.

That tag contains `Render::IWindowTransformer` and per-window transformer
storage. The upstream interface documentation is also explicit about a current
limitation: window transformers affect the main window pass, **not popups**.

Source:

- [Hyprland v0.56.2 `Transformer.hpp`](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/render/transformer/Transformer.hpp)

Therefore `IWindowTransformer` is useful evidence of a cleaner modern render
extension, but it is not yet proven to be a drop-in implementation of PSD's
monitor-wide spatial presentation transform. In particular, PSD must still
characterize popup composition, subsurfaces, decorations, damage and
direct-scanout behavior.

Newer upstream `main` contains additional transformer/effects infrastructure,
but PSD does not design against moving `main`. It can be reconsidered only
after that infrastructure exists in a pinned stable tag.


### Dedicated popup characterization checkpoint — CI #225

The dedicated backend now has explicit `xdg_popup` evidence rather than an
inference from `renderWindow()` call structure.

The Ubuntu 26.04 QEMU probe creates a deterministic Qt transient, confirms
`xdg_popup` creation from the Wayland protocol trace, and tracks only the
popup's exact solid-color pixels. With a 96 logical-unit PSD offset the popup
translated by 96 physical pixels at scale 1.0 with overlap 1.000, while the
toplevel logical geometry remained unchanged. Reset returned the popup to a
0-pixel translation with overlap 1.000.

Therefore popup composition is validated for the current dedicated
`renderWindow()` POC on Hyprland 0.53.3. This does not imply that
`IWindowTransformer` on Hyprland v0.56.2 has equivalent behavior; upstream
explicitly excludes popups from that transformer path.

Subsurface behavior remains a separate requirement and must be proven with an
actual `wl_subsurface` before promotion.


### Dedicated subsurface characterization checkpoint — CI #226

The dedicated backend now also has explicit `wl_subsurface` evidence.

The Ubuntu 26.04 QEMU probe forces a native Qt child window, confirms
`wl_subcompositor.get_subsurface` in the Wayland protocol trace, and follows
only that child surface's deterministic solid-color pixels. With a 96
logical-unit PSD offset, the subsurface translated by 96 physical pixels at
scale 1.0 with overlap 1.000. Reset returned it to a 0-pixel translation with
overlap 1.000, while the parent toplevel's logical geometry remained unchanged.

This validates subsurface composition for the current dedicated
`renderWindow()` POC on the Ubuntu 26.04 Hyprland target. Popup and subsurface
behavior are therefore both proven by protocol-aware pixel tests rather than
inferred from renderer call structure.

Compositor-owned decorations remain a separate requirement. The next
characterization uses a deterministic Hyprland border color that does not occur
in the client surface and correlates those border pixels independently from the
window contents.


### Dedicated compositor-decoration checkpoint — CI #227

The dedicated backend now has explicit compositor-owned decoration evidence.

The Ubuntu 26.04 QEMU session configures an 8-pixel solid magenta Hyprland
border while the client paints a color that cannot match that border. The
probe therefore correlates only compositor-owned decoration pixels. Under a 96
logical-unit PSD offset at scale 1.0, the border bounding box moved from
`x=392..887` to `x=488..983`, exactly 96 physical pixels, with overlap
1.000. Reset returned the border to its original bounding box with overlap
1.000.

This validates compositor decoration translation for the current dedicated
`renderWindow()` POC.

### Dedicated damage characterization

Damage is not inferred from successful screenshots alone. Hyprland 0.53.3's
native `CHyprRenderer::damageMonitor()` adds monitor-wide damage and
`CMonitor::addDamage()` schedules a frame when that damage is new. The
dedicated PSD dispatcher already calls this path when an offset is applied and
when it is reset.

The QEMU probe now enables Hyprland's native `debug:log_damage` output and
requires each dedicated apply/reset operation to produce a
`Damage: Monitor <name>` event. It also performs a strict old/new pixel-mask
comparison: translated client pixels must appear at the new position and no
stale client-colored pixels may remain in the old position.

Finally, after the apply-triggered and reset-triggered frames settle, the probe
holds the scene static and requires the monitor-damage count to remain stable.
This checks the architectural property that a persistent PSD offset is state,
not a polling/redraw loop. The dedicated hook itself contains no timer or
animation driver; subsequent rendering remains driven by compositor/client
damage and other normal Wayland events.
