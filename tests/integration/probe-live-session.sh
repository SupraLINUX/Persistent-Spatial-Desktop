#!/usr/bin/env bash
set -euo pipefail

SHELL_PATH="${1:-build/psd-shell}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    echo "PSD live probe: this must run inside the Hyprland session being tested." >&2
    exit 1
fi

for command in hyprctl python3 realpath; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "PSD live probe: missing command: $command" >&2
        exit 1
    fi
done

if [[ ! -e "$SHELL_PATH" ]]; then
    echo "PSD live probe: shell binary not found: $SHELL_PATH" >&2
    exit 1
fi

if [[ ! -e "$PLUGIN_PATH" ]]; then
    echo "PSD live probe: plugin not found: $PLUGIN_PATH" >&2
    exit 1
fi

SHELL_PATH="$(realpath "$SHELL_PATH")"
PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"

if [[ ! -x "$SHELL_PATH" ]]; then
    echo "PSD live probe: shell binary is not executable: $SHELL_PATH" >&2
    exit 1
fi

if [[ ! -f "$PLUGIN_PATH" ]]; then
    echo "PSD live probe: plugin path is not a regular file: $PLUGIN_PATH" >&2
    exit 1
fi

existing_psd_layer="$(hyprctl -j layers | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(str(x.get("namespace","")).startswith(("psd-shell:","psd-return-shield:")) for m in d.values() for level in m.get("levels",{}).values() for x in level))')"
if [[ "$existing_psd_layer" == "True" ]]; then
    echo "PSD live probe: a PSD shell/return-shield layer is already mapped; refusing to create a duplicate." >&2
    exit 1
fi

loaded_by_probe=0
shell_pid=""
log_file="${TMPDIR:-/tmp}/psd-live-session-probe.log"
runtime_restore_needed=0
runtime_monitor=""
runtime_workspace_selector=""
runtime_cursor_x=""
runtime_cursor_y=""

plugin_state() {
    hyprctl -j psd-plugin-state
}

reset_all_monitor_offsets() {
    if ! hyprctl -j psd-plugin >/dev/null 2>&1; then
        return
    fi

    local state_json='{"trackedTransforms":[]}'
    local monitors_json='[]'

    state_json="$(hyprctl -j psd-plugin-state 2>/dev/null || printf '%s' "$state_json")"
    monitors_json="$(hyprctl -j monitors 2>/dev/null || printf '%s' "$monitors_json")"

    while IFS= read -r monitor_name; do
        [[ -n "$monitor_name" ]] || continue
        hyprctl dispatch plugin:psd:reset "$monitor_name" >/dev/null 2>&1 || true
    done < <(
        python3 - "$state_json" "$monitors_json" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitors = json.loads(sys.argv[2])

names = {
    str(item.get("monitor", "")).strip()
    for item in state.get("trackedTransforms", [])
}
names.update(
    str(item.get("name", "")).strip()
    for item in monitors
)

for name in sorted(name for name in names if name):
    print(name)
PY
    )
}

restore_runtime_context() {
    if [[ "$runtime_restore_needed" != "1" ]]; then
        return
    fi

    if [[ -n "$runtime_monitor" ]]; then
        hyprctl dispatch focusmonitor "$runtime_monitor" >/dev/null 2>&1 || true
    fi

    if [[ -n "$runtime_workspace_selector" ]]; then
        hyprctl dispatch workspace "$runtime_workspace_selector" >/dev/null 2>&1 || true
    fi

    if [[ -n "$runtime_cursor_x" && -n "$runtime_cursor_y" ]]; then
        hyprctl dispatch movecursor "$runtime_cursor_x $runtime_cursor_y" >/dev/null 2>&1 || true
    fi

    runtime_restore_needed=0
}

cleanup() {
    set +e
    hyprctl dispatch plugin:psd:gesture-events 0 >/dev/null 2>&1 || true

    if [[ -n "$shell_pid" ]]; then
        kill -TERM "$shell_pid" >/dev/null 2>&1 || true

        for _ in $(seq 1 30); do
            if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done

        if kill -0 "$shell_pid" >/dev/null 2>&1; then
            kill -KILL "$shell_pid" >/dev/null 2>&1 || true
        fi

        wait "$shell_pid" >/dev/null 2>&1 || true
    fi

    # The compositor transform is experimental. Always restore every active
    # monitor after the shell has stopped so a failed probe cannot leave a
    # render offset behind when the plugin was already loaded by the session.
    reset_all_monitor_offsets
    restore_runtime_context

    if [[ "$loaded_by_probe" == "1" ]]; then
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

plugin_loaded="$(hyprctl -j plugin list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(x.get("name")=="psd-hyprland-plugin" for x in d))')"
if [[ "$plugin_loaded" != "True" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    loaded_by_probe=1
fi

capabilities="$(hyprctl -j psd-plugin)"
python3 - "$capabilities" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["protocolVersion"] == 3, data
assert data["spatialRenderOffsetExperimental"] is True, data
assert data["monitorTargeting"] is True, data
assert data["fourFingerGestureEventsExperimental"] is True, data
assert data["gestureEventsDefaultEnabled"] is False, data
assert data["diagnosticStateQueryExperimental"] is True, data
print("PSD live probe: plugin capability handshake PASS")
PY

initial_plugin_state="$(plugin_state)"
python3 - "$initial_plugin_state" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["trackedTransforms"] == [], data
assert data["gestureActive"] is False, data
print("PSD live probe: initial plugin state clean PASS")
PY

monitor_json="$(hyprctl -j monitors)"
monitor_count="$(python3 - "$monitor_json" <<'PY'
import json, sys
print(len(json.loads(sys.argv[1])))
PY
)"

if [[ "$monitor_count" -lt 1 ]]; then
    echo "PSD live probe: Hyprland reports no active monitors." >&2
    exit 1
fi

primary_monitor="$(python3 - "$monitor_json" <<'PY'
import json, sys
monitors = json.loads(sys.argv[1])
focused = next((m for m in monitors if m.get("focused")), monitors[0])
print(focused["name"])
PY
)"

PSD_EXPERIMENTAL_HYPRLAND_SYNC=1 "$SHELL_PATH" >"$log_file" 2>&1 &
shell_pid=$!

ready=0
for _ in $(seq 1 80); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
        echo "PSD live probe: psd-shell exited before mapping its surfaces." >&2
        cat "$log_file" >&2 || true
        exit 1
    fi

    layers_json="$(hyprctl -j layers)"
    if python3 - "$monitor_json" "$layers_json" <<'PY' >/dev/null 2>&1
import json
import sys

monitors = json.loads(sys.argv[1])
layers = json.loads(sys.argv[2])
expected_shells = {f"psd-shell:{m['name']}" for m in monitors}
seen_shells = []

for monitor in monitors:
    name = monitor["name"]
    expected_shell = f"psd-shell:{name}"
    forbidden_shield = f"psd-return-shield:{name}"
    monitor_layers = layers.get(name, {}).get("levels", {})
    namespaces = [
        layer.get("namespace", "")
        for level in monitor_layers.values()
        for layer in level
    ]

    if namespaces.count(expected_shell) != 1:
        raise SystemExit(1)
    if forbidden_shield in namespaces:
        raise SystemExit(1)

    seen_shells.extend(ns for ns in namespaces if ns.startswith("psd-shell:"))

if len(seen_shells) != len(monitors) or set(seen_shells) != expected_shells:
    raise SystemExit(1)
PY
    then
        ready=1
        break
    fi

    sleep 0.1
done

if [[ "$ready" != "1" ]]; then
    echo "PSD live probe: shell surfaces did not reach the expected per-monitor CENTER state." >&2
    hyprctl -j layers >&2 || true
    cat "$log_file" >&2 || true
    exit 1
fi

echo "PSD live probe: $monitor_count monitor-local shell surface(s), CENTER shields unmapped PASS"

hyprctl dispatch plugin:psd:gesture-events 1 | grep -qx "ok"
hyprctl dispatch plugin:psd:gesture-events 0 | grep -qx "ok"
echo "PSD live probe: four-finger gesture arm/disarm PASS"

if [[ "${PSD_PROBE_EXERCISE_OFFSET:-0}" == "1" ]]; then
    hyprctl dispatch plugin:psd:offset "$primary_monitor 24 0" | grep -qx "ok"

    offset_state="$(plugin_state)"
    python3 - "$offset_state" "$primary_monitor" <<'PY'
import json
import math
import sys

data = json.loads(sys.argv[1])
monitor = sys.argv[2]
matches = [x for x in data["trackedTransforms"] if x["monitor"] == monitor]
assert len(matches) == 1, data
transform = matches[0]
assert math.isclose(transform["x"], 24.0, abs_tol=0.01), transform
assert math.isclose(transform["y"], 0.0, abs_tol=0.01), transform
assert transform["workspaceGeneration"] > 0, transform
PY

    hyprctl dispatch plugin:psd:reset "$primary_monitor" | grep -qx "ok"

    reset_state="$(plugin_state)"
    python3 - "$reset_state" "$primary_monitor" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
monitor = sys.argv[2]
assert all(x["monitor"] != monitor for x in data["trackedTransforms"]), data
PY

    echo "PSD live probe: explicit offset/state/reset on $primary_monitor PASS"
fi

if [[ "${PSD_PROBE_EXERCISE_RUNTIME:-0}" == "1" ]]; then
    runtime_monitor="$primary_monitor"

    runtime_workspace_selector="$(python3 - "$monitor_json" "$primary_monitor" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
monitor_name = sys.argv[2]
monitor = next(m for m in monitors if m["name"] == monitor_name)
workspace = monitor.get("activeWorkspace", {})
name = str(workspace.get("name", "")).strip()

if not name:
    raise SystemExit("focused monitor has no active workspace name")

print(name if name.isdigit() else f"name:{name}")
PY
)"

    cursor_json="$(hyprctl -j cursorpos)"
    read -r runtime_cursor_x runtime_cursor_y < <(
        python3 - "$cursor_json" <<'PY'
import json
import sys

cursor = json.loads(sys.argv[1])
print(cursor["x"], cursor["y"])
PY
    )

    read -r runtime_center_x runtime_center_y runtime_edge_x runtime_edge_y < <(
        python3 - "$monitor_json" "$primary_monitor" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
monitor_name = sys.argv[2]
monitor = next(m for m in monitors if m["name"] == monitor_name)

scale = float(monitor.get("scale", 1.0) or 1.0)
width = float(monitor["width"])
height = float(monitor["height"])
transform = int(monitor.get("transform", 0) or 0)

if transform in (1, 3, 5, 7):
    width, height = height, width

width /= scale
height /= scale
x = float(monitor.get("x", 0))
y = float(monitor.get("y", 0))

print(
    round(x + width * 0.5),
    round(y + height * 0.5),
    round(x + 1),
    round(y + height * 0.5),
)
PY
    )

    runtime_restore_needed=1
    probe_workspace_a="psd-probe-$$-a"
    probe_workspace_b="psd-probe-$$-b"

    hyprctl dispatch focusmonitor "$primary_monitor" | grep -qx "ok"
    hyprctl dispatch workspace "name:$probe_workspace_a" | grep -qx "ok"

    hyprctl dispatch movecursor "$runtime_center_x $runtime_center_y" | grep -qx "ok"
    sleep 0.1
    hyprctl dispatch movecursor "$runtime_edge_x $runtime_edge_y" | grep -qx "ok"

    displaced=0
    first_generation=""
    first_reset_count=""

    for _ in $(seq 1 40); do
        layers_json="$(hyprctl -j layers)"
        state_json="$(plugin_state)"

        if read -r first_generation first_reset_count < <(
            python3 - "$layers_json" "$state_json" "$primary_monitor" <<'PY'
import json
import sys

layers = json.loads(sys.argv[1])
state = json.loads(sys.argv[2])
monitor = sys.argv[3]

namespaces = {
    layer.get("namespace", "")
    for level in layers.get(monitor, {}).get("levels", {}).values()
    for layer in level
}
if f"psd-return-shield:{monitor}" not in namespaces:
    raise SystemExit(1)

matches = [x for x in state["trackedTransforms"] if x["monitor"] == monitor]
if len(matches) != 1:
    raise SystemExit(1)

transform = matches[0]
if abs(float(transform["x"])) < 1.0 and abs(float(transform["y"])) < 1.0:
    raise SystemExit(1)

print(transform["workspaceGeneration"], state["workspaceSwitchResetCount"])
PY
        ); then
            displaced=1
            break
        fi

        sleep 0.1
    done

    if [[ "$displaced" != "1" ]]; then
        echo "PSD live probe: gutter navigation did not produce a displaced runtime state." >&2
        hyprctl -j layers >&2 || true
        plugin_state >&2 || true
        cat "$log_file" >&2 || true
        exit 1
    fi

    # The canonical spatial animation is 500 ms. Let the real transition
    # settle before changing workspaces so this checks retargeting of a stable
    # displaced state rather than an animation frame racing the workspace event.
    sleep 0.6

    echo "PSD live probe: real gutter navigation + compositor transform PASS"

    hyprctl dispatch workspace "name:$probe_workspace_b" | grep -qx "ok"

    retargeted=0
    for _ in $(seq 1 40); do
        state_json="$(plugin_state)"

        if python3 - "$state_json" "$primary_monitor" "$first_generation" "$first_reset_count" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
first_generation = int(sys.argv[3])
first_reset_count = int(sys.argv[4])

matches = [x for x in state["trackedTransforms"] if x["monitor"] == monitor]
if len(matches) != 1:
    raise SystemExit(1)

transform = matches[0]
if int(transform["workspaceGeneration"]) == first_generation:
    raise SystemExit(1)
if int(state["workspaceSwitchResetCount"]) <= first_reset_count:
    raise SystemExit(1)
if abs(float(transform["x"])) < 1.0 and abs(float(transform["y"])) < 1.0:
    raise SystemExit(1)
PY
        then
            retargeted=1
            break
        fi

        sleep 0.1
    done

    if [[ "$retargeted" != "1" ]]; then
        echo "PSD live probe: displaced workspace switch did not retarget the compositor transform." >&2
        plugin_state >&2 || true
        cat "$log_file" >&2 || true
        exit 1
    fi

    echo "PSD live probe: workspace retarget + previous-workspace reset PASS"

    kill -TERM "$shell_pid"

    shell_exited=0
    for _ in $(seq 1 50); do
        if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
            shell_exited=1
            break
        fi
        sleep 0.1
    done

    if [[ "$shell_exited" != "1" ]]; then
        echo "PSD live probe: psd-shell did not exit after SIGTERM." >&2
        cat "$log_file" >&2 || true
        exit 1
    fi

    wait "$shell_pid"
    shell_pid=""

    shutdown_clean=0
    for _ in $(seq 1 30); do
        state_json="$(plugin_state)"
        if python3 - "$state_json" <<'PY' >/dev/null 2>&1
import json
import sys

state = json.loads(sys.argv[1])
raise SystemExit(0 if state["trackedTransforms"] == [] else 1)
PY
        then
            shutdown_clean=1
            break
        fi
        sleep 0.1
    done

    if [[ "$shutdown_clean" != "1" ]]; then
        echo "PSD live probe: shell shutdown left an experimental compositor transform tracked." >&2
        plugin_state >&2 || true
        cat "$log_file" >&2 || true
        exit 1
    fi

    echo "PSD live probe: SIGTERM drain + final compositor reset PASS"

    restore_runtime_context
fi

echo "PSD live probe: PASS"
