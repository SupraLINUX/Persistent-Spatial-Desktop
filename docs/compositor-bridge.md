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

The first CI implementation (#228) attempted to observe
`debug:log_damage` through Hyprland's redirected logger. The backend did emit
`Damage: Monitor Virtual-1`, but the asynchronous log write became visible
just after the probe timeout, producing a false negative. Log-file timing is
therefore not used as correctness evidence.

The plugin now exposes two diagnostic per-monitor counters in
`psd-plugin-state`: `dedicatedDamageRequests` is incremented immediately
before the dedicated path calls `damageMonitor()`, and `monitorRenderCounts`
is incremented from Hyprland's `preRender` hook. The QEMU probe requires each
apply/reset to advance both counters, then requires both to become quiet while
the scene is static.

The probe still performs a strict old/new pixel-mask comparison: translated
client pixels must appear at the new position and no stale client-colored
pixels may remain in the old position. This combines synchronous request
evidence, compositor-frame evidence and final framebuffer correctness without
depending on logger flush latency.

A persistent PSD offset remains state rather than an animation source. The
dedicated hook contains no timer or polling loop; once the apply/reset frame
settles, no further dedicated damage requests should occur and the compositor
render counter must become idle until normal Wayland/compositor events require
another frame.


#### Damage probe harness correction — CI #229

CI #229 did not invalidate the dedicated damage path. The probe aborted before
the damage assertions because its `state_counter()` helper combined
`hyprctl ... | python3 -` with a heredoc containing the Python program. The
heredoc owns standard input, so the Python process could not consume the piped
JSON state; under `set -e` the command substitution terminated the probe.

The helper now captures `psd-plugin-state` first and passes the JSON to Python
as an explicit argument. No compositor/backend behavior changed in this fix.


#### Damage probe harness correction — CI #230

CI #230 also exited before reaching any damage assertion. The dedicated damage
case accidentally constructed its title as `psd-render-$mode-$`. The trailing
literal dollar sign then became an end-of-string regex anchor when the title
was reused by `focuswindow`, so the focus dispatcher did not match the actual
client and `set -e` terminated the probe.

The test now uses `psd-render-${mode}-${BASHPID}`, giving the client a
regex-safe unique title. No compositor/backend code changed in this correction.


### Dedicated damage checkpoint — CI #231

The deterministic damage probe passed end-to-end.

Applying the dedicated offset advanced the monitor-local damage-request counter
from 12 to 13 and the compositor `preRender` counter from 86 to 87. Both then
remained stable during the idle observation window. Reset advanced the same
counters from 13 to 14 and from 88 to 89 respectively, and again became idle.
The framebuffer mask moved by +96 physical pixels on apply and -96 on reset
without stale client-colored pixels remaining at the previous location.

For the current dedicated POC this closes the damage/event-driven
characterization: a persistent offset does not itself create a redraw loop.

### Explicit fullscreen and direct-scanout invariant

Hyprland 0.53.3 attempts direct scanout in `CMonitor::attemptDirectScanout()`
before the normal render pass, therefore before PSD's `renderWindow()` hook.
Its solitary-candidate path requires fullscreen content. A PSD presentation
offset is private plugin state and is not represented by
`CWorkspace::m_renderOffset`, so allowing explicit fullscreen to coexist with
a non-zero dedicated offset would create a bypass risk.

PSD therefore enforces the following compositor-side invariant:

> explicit fullscreen and a non-zero dedicated PSD offset never coexist.

The plugin listens to Hyprland's native `fullscreen` hook. If a window enters
effective `FSMODE_FULLSCREEN` while its monitor has a dedicated PSD offset,
the plugin erases that offset and damages the monitor immediately. While
explicit fullscreen remains active, new dedicated offset requests are refused.
Leaving fullscreen does not resurrect the previous displacement.

This rule intentionally does **not** apply to `FSMODE_MAXIMIZED`. Maximized
windows belong to CENTER according to the PSD product model and remain
spatially movable with CENTER.

PSD does not toggle Hyprland's global `m_directScanoutBlocked` boolean for
this purpose. That flag is also used by other compositor subsystems such as
screen sharing; treating it as plugin-owned state would create an unsafe
ownership collision.

The QEMU characterization enables `render:direct_scanout=1` and verifies the
fullscreen/offset invariant plus the recenter damage/frame. It records
Hyprland's direct-scanout diagnostic state, but does not claim successful
zero-copy scanout unless the guest/client actually provides a scanout-capable
DMA-BUF. Real DRM/NVIDIA direct-scanout validation therefore remains a
hardware-specific requirement.


#### Direct-scanout probe harness correction — CI #232

CI #232 reached and passed the complete dedicated damage probe, then exited at
the start of the new direct-scanout guard before any fullscreen assertion ran.
The generated Bash source had preserved escapes around
`${mode}` and `${BASHPID}`, so the client title contained literal shell
syntax. Reusing that title as a Hyprland window regex prevented the guard from
targeting the window correctly.

The title now expands normally at Bash runtime. The probe also prints an
explicit guard-entry marker and its cleanup trap always restores
`render:direct_scanout=0`, including failure paths. No compositor/backend
semantics changed in this correction.


### Fullscreen/direct-scanout guard checkpoint — CI #233

The compositor-side invariant passed in QEMU with
`render:direct_scanout=1`.

The probe confirmed that `FSMODE_MAXIMIZED` remains spatially movable with
CENTER. Entering explicit `FSMODE_FULLSCREEN` while a dedicated offset was
active advanced the fullscreen recenter counter from 0 to 1, advanced the
dedicated damage counter from 15 to 16, and produced new compositor frames.
The resulting fullscreen window occupied the complete monitor with no
dedicated PSD offset, and additional offset requests were rejected until
fullscreen exited.

Hyprland reported `directScanoutTo=0` with blocking reasons `SW` and
`SURFACE` in the QEMU guest. Therefore CI validates the safety invariant but
does not claim that real DRM/KMS zero-copy scanout occurred. Hardware direct
scanout, especially the NVIDIA path, remains a later hardware validation item.

### Fractional-scale characterization

The CI characterization reuses the complete dedicated render suite under a
fractional monitor scale rather than introducing a reduced special-case test.

PSD geometry is defined in logical units. Screenshot validation therefore
normalizes `grim` to image scale 1, producing one PNG pixel per Wayland layout
unit. Under that normalized capture a standard 96-logical-unit PSD displacement
must correlate as 96 screenshot pixels regardless of the monitor's effective
scale. The compositor/output pipeline remains responsible for mapping those
logical units to physical DRM pixels.

This pass covers tiled, floating and pinned windows, xdg_popup, wl_subsurface,
compositor decorations, damage/event-driven behavior and the
fullscreen/direct-scanout guard under fractional scaling. The runtime restores
the original monitor scale before continuing with later probes and also
restores it from the cleanup trap on failure.


#### Fractional-scale harness correction — CI #234

CI #234 did not reach the fractional-scale characterization. The new runtime
helper repeated the same pipe-plus-heredoc stdin collision previously removed
from the damage probe: `hyprctl -j monitors | python3 - <<'PY'` caused the
heredoc carrying the Python program to replace the JSON stream on standard
input, producing `JSONDecodeError` before the render suite started.

The runtime now captures `hyprctl -j monitors` first and passes the JSON as an
explicit Python argument. A scan of the integration scripts confirmed no other
`python3 -` heredoc is fed simultaneously by a pipe; existing piped helpers
use `python3 -c` and consume stdin normally. No compositor/backend code
changed in this correction.


#### Fractional-scale normalization checkpoint — CI #235

CI #235 reached the fractional-scale setup for the first time. Hyprland
accepted the requested scale 1.5 but reported an effective scale of 1.60 on the
1280x800 QEMU output.

This is expected Hyprland 0.53.3 behavior rather than a backend failure.
`CMonitor::applyMonitorRule()` checks whether `pixelSize / scale` produces
integer logical dimensions. If not, it searches in 1/120 increments for the
nearest scale that is a clean divisor. For 1280x800, scale 1.6 yields an exact
800x500 logical output.

The CI therefore no longer assumes that the requested fractional scale is the
effective one. It requests 1.5, waits for Hyprland to settle on a scale that is
both different from the original and genuinely fractional, records that live
effective value, and then runs the complete dedicated render suite. Pixel
correlation is performed in normalized logical screenshot coordinates, not by
multiplying the PSD offset by the monitor scale.


#### Fractional-scale coordinate checkpoint — CI #236

CI #236 reached the complete dedicated render suite at effective scale 1.6.
The first tiled case rendered a coherent 96-unit translation with overlap
1.000, while the probe expected 154 because it had multiplied the logical PSD
offset by the monitor scale.

That expectation mixed two coordinate systems. `grim` has its own output
image scale, and fractional-output geometry is represented through xdg-output.
Raw PNG coordinates are therefore not a stable synonym for DRM physical
pixels.

The probe now captures with `grim -s 1` and verifies the resulting PNG
dimensions against `pixelSize / effectiveScale`. This gives a deterministic
logical-coordinate raster: on the current 1280x800 QEMU output at scale 1.6,
the normalized image must be 800x500. All render-offset assertions then compare
the 96 logical PSD units against 96 normalized screenshot pixels.

No compositor/backend code changed in this correction. The purpose is to test
the unit contract PSD actually exposes rather than an incidental screenshot
tool scale.


#### Fractional-scale raster calibration — CI #237

CI #237 showed that `grim -s 1` still produced a 1280x800 PNG for the
1280x800 output at monitor scale 1.6. Therefore `-s 1` cannot be treated as a
guarantee that one image pixel equals one PSD logical unit on this compositor
path.

The probe now measures the screenshot coordinate factor instead of assuming
it. For transform 0 it derives the monitor's logical extent as
`pixelSize / monitorScale`, compares that with the actual PNG dimensions, and
computes `screenshotPxPerLogical`. Every translation expectation is then
`logicalOffset * screenshotPxPerLogical`.

The fractional run also executes the legacy backend first as a diagnostic
control and records its exit status without preventing the dedicated backend
from running. This is useful because the legacy path primarily uses
`CWorkspace::m_renderOffset`, while its pinned compensation and the dedicated
POC both use `CWindow::m_floatingOffset`. A split result will therefore
localize any scale-unit mismatch rather than attributing it generically to
screencopy or HiDPI.


#### Fractional calibration harness correction — CI #238

CI #238 did not reach the fractional-scale control pass. The dedicated scale-1
suite stopped in the xdg_popup case because screenshot calibration had been
inserted inside the popup visibility loop before that function declared its
`logical_offset`. With `set -u`, Bash terminated on the unbound variable.

The xdg_popup and wl_subsurface cases now declare their calibration inputs
before their first baseline capture. The tiled/floating/pinned, decoration and
damage cases were already ordered correctly. No compositor/backend behavior
changed in this correction.


### Fractional-scale unit conversion — after CI #239

CI #239 finally produced a controlled fractional-scale result. At effective
monitor scale 1.6, the screenshot calibration measured
`screenshotPxPerLogical=1.6`. The legacy tiled control received a PSD offset
of 96 logical units but moved only 96 screenshot pixels; the expected logical
distance was 154 screenshot pixels. This localizes a real unit mismatch between
PSD's logical geometry contract and the render-offset values passed into
Hyprland.

PSD's runtime computes spatial destinations from Qt screen/layout geometry and
`SpatialCompositorSync` forwards those offsets unchanged to the compositor.
The plugin API therefore remains logical-unit based.

Plugin 0.1.7 converts logical PSD offsets to Hyprland render units internally
using the target monitor's live scale:

`renderOffset = logicalOffset * monitorScale`.

The conversion is applied to both experimental paths:

- legacy workspace `m_renderOffset`;
- pinned legacy `m_floatingOffset` compensation;
- dedicated render-time `m_floatingOffset` composition.

The dedicated path performs the conversion inside each `renderWindow()` call,
so an already-stored logical offset automatically follows the monitor's current
scale without rewriting plugin state. Diagnostic
`dedicatedPresentationOffsets` continues to expose the original logical
values.

The fractional CI now requires the legacy control to pass instead of accepting
its failure, then explicitly reapplies the effective fractional monitor scale
before launching the dedicated probe. This prevents plugin lifecycle/config
reload effects from silently returning the dedicated pass to scale 1.0.


#### HiDPI internal-unit diagnostic — after CI #240

CI #240 showed that the first 0.1.7 conversion attempt did not change the
legacy fractional result: the externally requested 96-unit offset still
correlated as 96 screenshot pixels at effective scale 1.6. The tracked
workspace state also reported `actual=96`, despite the source containing the
new logical-to-render multiplication.

Before changing the conversion again, plugin state now records the exact
internal values seen during each legacy apply: monitor scale, logical
`m_size`, physical `m_pixelSize`, requested logical offset, computed render
offset, and the animated variable value immediately after
`setValueAndWarp()`. The render probe also requires
`pluginVersion == 0.1.7`, ruling out a stale plugin artifact.

The fractional legacy pass is temporarily diagnostic again so the dedicated
pass can still execute after the internal values are captured. This
instrumentation is intentionally non-architectural and should be removed or
narrowed once the coordinate-space mismatch is resolved.


### Fractional-scale plugin lifecycle correction — after CI #241

CI #241 exposed the missing piece in the HiDPI investigation. Immediately
before the child render probe, `hyprctl monitors` reported scale 1.6. Inside
the plugin, after the child probe had performed its plugin load step, the same
monitor was observed as scale 1.0 with logical size 1280x800 and pixel size
1280x800. Both legacy and dedicated therefore moved 96 raster pixels.

This means the earlier fractional tests were crossing a plugin/config lifecycle
boundary between the monitor-scale measurement and the actual render-offset
application. The scale seen by the plugin was no longer the scale captured by
the harness.

The runtime now loads the PSD plugin **before** applying fractional scale and
keeps that same plugin instance loaded across both the legacy and dedicated
fractional probes. The scale is changed only after plugin-load side effects have
settled, so the test and plugin observe the same monitor state. The plugin is
unloaded after the fractional block and also from cleanup on failure.

Plugin 0.1.8 also removes the 0.1.7 `logicalOffset * monitorScale`
conversion. Hyprland 0.53.3 keeps workspace/window positions and
`m_renderOffset` / `m_floatingOffset` in logical layout coordinates; the
renderer multiplies those coordinates by output scale later when building the
rasterized surface and damage boxes. Multiplying in PSD would therefore apply
scale twice once the plugin actually sees the fractional monitor state.

The internal conversion diagnostic remains temporarily enabled for the next CI
pass. The expected successful fractional diagnostic is approximately:

- monitor scale: 1.6;
- logical monitor size: 800x500;
- pixel size: 1280x800;
- logical/render requested offset: 96;
- actual workspace offset after apply: 96;
- screenshot correlation: approximately 154 pixels.


### Fractional-scale checkpoint — CI #242

CI #242 closed the fractional-scale characterization. After loading the plugin
before changing monitor scale, both the harness and the plugin observed the
same output state:

- effective scale 1.6;
- logical monitor size 800x500;
- pixel size 1280x800;
- PSD offset stored and applied as 96 logical units.

At scale 1.6, `grim -s 1` produced an 800x500 logical-coordinate image.
Legacy tiled/floating/pinned all passed. The dedicated backend also passed
tiled/floating/pinned, xdg_popup, wl_subsurface, compositor decorations,
damage/event-driven checks, and the fullscreen/direct-scanout guard.

The observed tiled displacement was 98 screenshot pixels rather than exactly
96 because of raster/mask edge sampling, with overlap 0.999; the probe's
existing tolerance accepted it. Other dedicated cases were 94–97 pixels with
overlap 1.000. This is consistent with the logical-coordinate contract and the
fractional rasterization boundary.

The temporary internal HiDPI conversion diagnostic has now been removed.
Plugin 0.1.9 keeps PSD offsets in Hyprland logical layout coordinates and does
not apply an extra monitor-scale multiplication.

### Monitor-transform characterization

The next CI checkpoint targets a 90-degree output transform
(`transform=1`) at scale 1.0. Because screencopy orientation may map a
logical horizontal displacement onto either PNG axis, this first
characterization intentionally validates the translation vector magnitude
rather than hard-coding X/Y orientation.

A compact floating dedicated-backend client is displaced by 96 logical units.
The probe requires:

- unchanged Hyprland logical window geometry;
- stable deterministic pixel area;
- a screenshot-mask translation vector with magnitude approximately 96 pixels;
- reset returning the vector magnitude to zero.

Once the observed screencopy vector is known, later transform coverage can
tighten direction semantics and extend to additional transform values.


#### Monitor-transform harness correction — CI #243

CI #243 did not reach the rotated-output render probe. Hyprland accepted
`monitor <name>,transform,1` but the live monitor remained at transform 0.

The exact 0.53.3 parser explains this behavior: the special
`<name>,transform,<n>` branch updates the matching stored monitor rule and
returns immediately. It does not follow the normal full-rule path that parses
mode, position, scale and transform together before monitor reconfiguration.

The runtime now applies transforms with a complete monitor rule:

`<name>,preferred,auto,<current-scale>,transform,<n>`

and waits until `hyprctl monitors` reports the requested live transform.
No PSD compositor/plugin semantics changed in this correction.


#### Monitor-transform checkpoint — CI #244

CI #244 successfully applied a real 90-degree output transform
(`transform=1`) and ran the dedicated render-only characterization.

Observed evidence:

- live monitor transform reached 1;
- logical window geometry remained unchanged;
- applying a 96-unit PSD X offset produced screenshot vector
  `(96, 0)`;
- translation magnitude was exactly 96 pixels;
- target pixel count ratio remained exactly 1.0000;
- reset produced vector `(0, 0)`;
- the complete QEMU probe finished PASS.

Because transformed screencopy preserved the logical X direction for
`transform=1`, the next checkpoint broadens the same invariant across every
non-normal Wayland output transform, 1 through 7. Each transform is applied
using the full monitor rule path, then the dedicated transform-only probe
verifies logical geometry immutability, stable target area, 96-unit visual
translation magnitude and exact reset. Scale remains 1.0 so transform behavior
is isolated from the already-closed fractional-scale characterization.
