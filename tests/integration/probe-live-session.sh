#!/usr/bin/env bash
set -euo pipefail

SHELL_PATH="${1:-build/psd-shell}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"
test_client_path="${PSD_PROBE_TEST_CLIENT:-}"

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

if [[ -n "$test_client_path" ]]; then
    if [[ ! -e "$test_client_path" ]]; then
        echo "PSD live probe: integration client not found: $test_client_path" >&2
        exit 1
    fi

    test_client_path="$(realpath "$test_client_path")"
    if [[ ! -x "$test_client_path" ]]; then
        echo "PSD live probe: integration client is not executable: $test_client_path" >&2
        exit 1
    fi
fi

existing_psd_layer="$(hyprctl -j layers | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(str(x.get("namespace","")).startswith(("psd-shell:","psd-return-shield:")) for m in d.values() for level in m.get("levels",{}).values() for x in level))')"
if [[ "$existing_psd_layer" == "True" ]]; then
    echo "PSD live probe: a PSD shell/return-shield layer is already mapped; refusing to create a duplicate." >&2
    exit 1
fi

loaded_by_probe=0
shell_pid=""
log_file="${TMPDIR:-/tmp}/psd-live-session-probe.log"
client_log_file="${TMPDIR:-/tmp}/psd-integration-client.log"
client_pids=()
hotplug_monitor=""
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

remove_hotplug_output() {
    if [[ -z "$hotplug_monitor" ]]; then
        return 0
    fi

    local monitor_to_remove="$hotplug_monitor"
    hyprctl output remove "$monitor_to_remove" >/dev/null 2>&1 || return 1

    for _ in $(seq 1 50); do
        local monitors_json layers_json
        monitors_json="$(hyprctl -j monitors 2>/dev/null || printf '[]')"
        layers_json="$(hyprctl -j layers 2>/dev/null || printf '{}')"

        if python3 - "$monitors_json" "$layers_json" "$monitor_to_remove" <<'PY' >/dev/null 2>&1
import json
import sys

monitors = json.loads(sys.argv[1])
layers = json.loads(sys.argv[2])
name = sys.argv[3]

if any(m.get("name") == name for m in monitors):
    raise SystemExit(1)

for monitor_layers in layers.values():
    for level in monitor_layers.get("levels", {}).values():
        for layer in level:
            if layer.get("namespace") == f"psd-shell:{name}":
                raise SystemExit(1)
PY
        then
            hotplug_monitor=""
            return 0
        fi

        sleep 0.1
    done

    return 1
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

    for client_pid in "${client_pids[@]}"; do
        [[ -n "$client_pid" ]] || continue
        kill -TERM "$client_pid" >/dev/null 2>&1 || true
        wait "$client_pid" >/dev/null 2>&1 || true
    done

    remove_hotplug_output >/dev/null 2>&1 || true

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
assert data["lifecycleEventsExperimental"] is True, data
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

if [[ "${PSD_PROBE_EXERCISE_HOTPLUG:-0}" == "1" ]]; then
    baseline_monitors="$(hyprctl -j monitors)"
    hyprctl output create headless PSD-PROBE >/dev/null

    hotplug_ready=0
    for _ in $(seq 1 50); do
        current_monitors="$(hyprctl -j monitors)"
        layers_json="$(hyprctl -j layers)"

        if hotplug_monitor="$(
            python3 - "$baseline_monitors" "$current_monitors" "$layers_json" <<'PY'
import json
import sys

baseline = {m["name"] for m in json.loads(sys.argv[1])}
current = json.loads(sys.argv[2])
layers = json.loads(sys.argv[3])

added = [m["name"] for m in current if m.get("name") not in baseline]
if len(added) != 1:
    raise SystemExit(1)

name = added[0]
namespaces = [
    layer.get("namespace", "")
    for level in layers.get(name, {}).get("levels", {}).values()
    for layer in level
]
if namespaces.count(f"psd-shell:{name}") != 1:
    raise SystemExit(1)
if f"psd-return-shield:{name}" in namespaces:
    raise SystemExit(1)

print(name)
PY
        )"; then
            hotplug_ready=1
            break
        fi

        sleep 0.1
    done

    if [[ "$hotplug_ready" != "1" ]]; then
        echo "PSD live probe: hotplugged output did not receive its own CENTER shell surface." >&2
        hyprctl -j monitors >&2 || true
        hyprctl -j layers >&2 || true
        exit 1
    fi

    echo "PSD live probe: monitor hot-add + independent CENTER surface on $hotplug_monitor PASS"
fi

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

    persistent_client_title=""
    if [[ -n "$test_client_path" ]]; then
        persistent_client_title="psd-probe-persistent"
        "$test_client_path" --title "$persistent_client_title" >"$client_log_file" 2>&1 &
        persistent_client_pid=$!
        client_pids+=("$persistent_client_pid")

        persistent_ready=0
        for _ in $(seq 1 50); do
            clients_json="$(hyprctl -j clients)"
            if python3 - "$clients_json" "$persistent_client_title" "$probe_workspace_a" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
title = sys.argv[2]
workspace_name = sys.argv[3]

for client in clients:
    workspace = client.get("workspace", {})
    if client.get("title") == title and str(workspace.get("name", "")) == workspace_name:
        raise SystemExit(0)

raise SystemExit(1)
PY
            then
                persistent_ready=1
                break
            fi
            sleep 0.1
        done

        if [[ "$persistent_ready" != "1" ]]; then
            echo "PSD live probe: persistent integration client did not map on workspace $probe_workspace_a." >&2
            hyprctl -j clients >&2 || true
            cat "$client_log_file" >&2 || true
            exit 1
        fi

        echo "PSD live probe: persistent Wayland client on previous workspace PASS"
    fi

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
if len(matches) != 1 or len(state["trackedTransforms"]) != 1:
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
    retarget_mode=""
    for _ in $(seq 1 40); do
        state_json="$(plugin_state)"
        workspaces_json="$(hyprctl -j workspaces)"

        if retarget_mode="$(
            python3 - "$state_json" "$workspaces_json" "$primary_monitor" "$first_generation" "$first_reset_count" "$probe_workspace_a" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
workspaces = json.loads(sys.argv[2])
monitor = sys.argv[3]
first_generation = int(sys.argv[4])
first_reset_count = int(sys.argv[5])
previous_workspace_name = sys.argv[6]

matches = [x for x in state["trackedTransforms"] if x["monitor"] == monitor]
if len(matches) != 1:
    raise SystemExit(1)

transform = matches[0]
if int(transform["workspaceGeneration"]) == first_generation:
    raise SystemExit(1)
if abs(float(transform["x"])) < 1.0 and abs(float(transform["y"])) < 1.0:
    raise SystemExit(1)

previous_still_exists = any(
    str(workspace.get("name", "")) == previous_workspace_name
    for workspace in workspaces
)

if previous_still_exists:
    if int(state["workspaceSwitchResetCount"]) <= first_reset_count:
        raise SystemExit(1)
    print("reset")
else:
    # Empty temporary workspaces are destroyed by Hyprland when switching
    # away from them. In that case their render-offset object disappears with
    # the workspace, so there is nothing left for the plugin to reset.
    print("destroyed")
PY
        )"; then
            retargeted=1
            break
        fi

        sleep 0.1
    done

    if [[ "$retargeted" != "1" ]]; then
        echo "PSD live probe: displaced workspace switch did not retarget the compositor transform." >&2
        plugin_state >&2 || true
        hyprctl -j workspaces >&2 || true
        cat "$log_file" >&2 || true
        exit 1
    fi

    if [[ -n "$test_client_path" && "$retarget_mode" != "reset" ]]; then
        echo "PSD live probe: persistent previous workspace was unexpectedly destroyed during retarget." >&2
        hyprctl -j workspaces >&2 || true
        exit 1
    fi

    if [[ "$retarget_mode" == "reset" ]]; then
        echo "PSD live probe: workspace retarget + previous-workspace reset PASS"
    else
        echo "PSD live probe: workspace retarget + previous empty workspace destroyed PASS"
    fi

    if [[ "${PSD_PROBE_EXERCISE_CRASH_RECOVERY:-0}" == "1" ]]; then
        # The workspace is already genuinely displaced by the real gutter path.
        # Kill the shell here so the test exercises an actual PSD-owned transform,
        # not a synthetic plugin command or a second hover sequence.
        sleep 0.6
        kill -KILL "$shell_pid"
        wait "$shell_pid" >/dev/null 2>&1 || true
        shell_pid=""

        residual_state="$(plugin_state)"
        recovery_mode="$(
            python3 - "$residual_state" "$primary_monitor" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
matches = [x for x in state.get("trackedTransforms", []) if x.get("monitor") == monitor]

if not matches:
    print("already-clean")
else:
    transform = matches[0]
    if abs(float(transform.get("x", 0.0))) < 1.0 and abs(float(transform.get("y", 0.0))) < 1.0:
        print("already-clean")
    else:
        print("residual")
PY
        )"

        echo "PSD live probe: SIGKILL compositor state after shell death = $recovery_mode"

        hyprctl dispatch movecursor "$runtime_center_x $runtime_center_y" | grep -qx "ok"

        PSD_EXPERIMENTAL_HYPRLAND_SYNC=1 "$SHELL_PATH" >>"$log_file" 2>&1 &
        shell_pid=$!

        recovery_ready=0
        for _ in $(seq 1 80); do
            if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
                echo "PSD live probe: psd-shell exited during SIGKILL recovery restart." >&2
                cat "$log_file" >&2 || true
                exit 1
            fi

            layers_json="$(hyprctl -j layers)"
            state_json="$(plugin_state)"

            monitors_json="$(hyprctl -j monitors)"
            if python3 - "$layers_json" "$state_json" "$monitors_json" <<'PY' >/dev/null 2>&1
import json
import sys

layers = json.loads(sys.argv[1])
state = json.loads(sys.argv[2])
monitors = json.loads(sys.argv[3])

for monitor in monitors:
    name = monitor["name"]
    namespaces = [
        layer.get("namespace", "")
        for level in layers.get(name, {}).get("levels", {}).values()
        for layer in level
    ]
    if namespaces.count(f"psd-shell:{name}") != 1:
        raise SystemExit(1)
    if f"psd-return-shield:{name}" in namespaces:
        raise SystemExit(1)

if state.get("trackedTransforms"):
    raise SystemExit(1)
PY
            then
                recovery_ready=1
                break
            fi

            sleep 0.1
        done

        if [[ "$recovery_ready" != "1" ]]; then
            echo "PSD live probe: restart after SIGKILL did not recover a clean CENTER state." >&2
            hyprctl -j layers >&2 || true
            plugin_state >&2 || true
            cat "$log_file" >&2 || true
            exit 1
        fi

        echo "PSD live probe: SIGKILL + restart recovery to clean CENTER PASS"
    fi


    if [[ -n "$test_client_path" ]]; then
        fullscreen_title="psd-probe-fullscreen"
        "$test_client_path" --title "$fullscreen_title" >>"$client_log_file" 2>&1 &
        fullscreen_pid=$!
        client_pids+=("$fullscreen_pid")

        fullscreen_client_ready=0
        for _ in $(seq 1 50); do
            clients_json="$(hyprctl -j clients)"
            if python3 - "$clients_json" "$fullscreen_title" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
title = sys.argv[2]
raise SystemExit(0 if any(c.get("title") == title for c in clients) else 1)
PY
            then
                fullscreen_client_ready=1
                break
            fi
            sleep 0.1
        done

        if [[ "$fullscreen_client_ready" != "1" ]]; then
            echo "PSD live probe: fullscreen integration client did not map." >&2
            hyprctl -j clients >&2 || true
            cat "$client_log_file" >&2 || true
            exit 1
        fi

        hyprctl dispatch focuswindow "title:^$fullscreen_title$" | grep -qx "ok"
        hyprctl dispatch fullscreen 0 | grep -qx "ok"

        fullscreen_ready=0
        for _ in $(seq 1 60); do
            clients_json="$(hyprctl -j clients)"
            layers_json="$(hyprctl -j layers)"
            state_json="$(plugin_state)"

            if python3 - "$clients_json" "$layers_json" "$state_json" "$primary_monitor" "$fullscreen_title" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
layers = json.loads(sys.argv[2])
state = json.loads(sys.argv[3])
monitor = sys.argv[4]
title = sys.argv[5]

client = next((c for c in clients if c.get("title") == title), None)
if client is None or int(client.get("fullscreen", 0) or 0) <= 0:
    raise SystemExit(1)

namespaces = {
    layer.get("namespace", "")
    for level in layers.get(monitor, {}).get("levels", {}).values()
    for layer in level
}
if f"psd-shell:{monitor}" in namespaces or f"psd-return-shield:{monitor}" in namespaces:
    raise SystemExit(1)

if any(x.get("monitor") == monitor for x in state.get("trackedTransforms", [])):
    raise SystemExit(1)
PY
            then
                fullscreen_ready=1
                break
            fi

            sleep 0.1
        done

        if [[ "$fullscreen_ready" != "1" ]]; then
            echo "PSD live probe: fullscreen did not suppress shell/reset transform on $primary_monitor." >&2
            hyprctl -j clients >&2 || true
            hyprctl -j layers >&2 || true
            plugin_state >&2 || true
            cat "$log_file" >&2 || true
            cat "$client_log_file" >&2 || true
            exit 1
        fi

        echo "PSD live probe: fullscreen enter suppresses shell + resets transform PASS"

        hyprctl dispatch fullscreen 0 | grep -qx "ok"

        fullscreen_exit_ready=0
        for _ in $(seq 1 60); do
            clients_json="$(hyprctl -j clients)"
            layers_json="$(hyprctl -j layers)"
            state_json="$(plugin_state)"

            if python3 - "$clients_json" "$layers_json" "$state_json" "$primary_monitor" "$fullscreen_title" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
layers = json.loads(sys.argv[2])
state = json.loads(sys.argv[3])
monitor = sys.argv[4]
title = sys.argv[5]

client = next((c for c in clients if c.get("title") == title), None)
if client is None or int(client.get("fullscreen", 0) or 0) != 0:
    raise SystemExit(1)

namespaces = [
    layer.get("namespace", "")
    for level in layers.get(monitor, {}).get("levels", {}).values()
    for layer in level
]
if namespaces.count(f"psd-shell:{monitor}") != 1:
    raise SystemExit(1)
if f"psd-return-shield:{monitor}" in namespaces:
    raise SystemExit(1)
if any(x.get("monitor") == monitor for x in state.get("trackedTransforms", [])):
    raise SystemExit(1)
PY
            then
                fullscreen_exit_ready=1
                break
            fi

            sleep 0.1
        done

        if [[ "$fullscreen_exit_ready" != "1" ]]; then
            echo "PSD live probe: shell did not return cleanly to CENTER after fullscreen exit." >&2
            hyprctl -j clients >&2 || true
            hyprctl -j layers >&2 || true
            plugin_state >&2 || true
            exit 1
        fi

        echo "PSD live probe: fullscreen exit remaps clean CENTER shell PASS"

        kill -TERM "$fullscreen_pid" >/dev/null 2>&1 || true
        wait "$fullscreen_pid" >/dev/null 2>&1 || true
    fi

    if [[ "${PSD_PROBE_EXERCISE_PLUGIN_LIFECYCLE:-0}" == "1" ]]; then
        hyprctl dispatch movecursor "$runtime_center_x $runtime_center_y" | grep -qx "ok"
        sleep 0.1
        hyprctl dispatch movecursor "$runtime_edge_x $runtime_edge_y" | grep -qx "ok"

        lifecycle_displaced=0
        for _ in $(seq 1 50); do
            layers_json="$(hyprctl -j layers)"
            state_json="$(plugin_state)"

            if python3 - "$layers_json" "$state_json" "$primary_monitor" <<'PY' >/dev/null 2>&1
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
matches = [x for x in state.get("trackedTransforms", []) if x.get("monitor") == monitor]

if f"psd-return-shield:{monitor}" not in namespaces:
    raise SystemExit(1)
if len(matches) != 1 or len(state.get("trackedTransforms", [])) != 1:
    raise SystemExit(1)
if abs(float(matches[0].get("x", 0.0))) < 1.0 and abs(float(matches[0].get("y", 0.0))) < 1.0:
    raise SystemExit(1)
PY
            then
                lifecycle_displaced=1
                break
            fi
            sleep 0.1
        done

        if [[ "$lifecycle_displaced" != "1" ]]; then
            echo "PSD live probe: could not establish displaced state before plugin lifecycle test." >&2
            hyprctl -j layers >&2 || true
            plugin_state >&2 || true
            exit 1
        fi

        sleep 0.6
        hyprctl plugin unload "$PLUGIN_PATH" | grep -qx "ok"

        unload_centered=0
        for _ in $(seq 1 60); do
            plugins_json="$(hyprctl -j plugin list)"
            layers_json="$(hyprctl -j layers)"
            monitors_json="$(hyprctl -j monitors)"

            if python3 - "$plugins_json" "$layers_json" "$monitors_json" <<'PY' >/dev/null 2>&1
import json
import sys

plugins = json.loads(sys.argv[1])
layers = json.loads(sys.argv[2])
monitors = json.loads(sys.argv[3])

if any(plugin.get("name") == "psd-hyprland-plugin" for plugin in plugins):
    raise SystemExit(1)

for monitor in monitors:
    name = monitor["name"]
    namespaces = [
        layer.get("namespace", "")
        for level in layers.get(name, {}).get("levels", {}).values()
        for layer in level
    ]
    if namespaces.count(f"psd-shell:{name}") != 1:
        raise SystemExit(1)
    if f"psd-return-shield:{name}" in namespaces:
        raise SystemExit(1)
PY
            then
                unload_centered=1
                break
            fi
            sleep 0.1
        done

        if [[ "$unload_centered" != "1" ]]; then
            echo "PSD live probe: plugin unload did not force every shell instance back to CENTER." >&2
            hyprctl -j plugin list >&2 || true
            hyprctl -j layers >&2 || true
            cat "$log_file" >&2 || true
            exit 1
        fi

        echo "PSD live probe: plugin unload while displaced -> clean CENTER PASS"

        hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"

        reload_ready=0
        for _ in $(seq 1 60); do
            capabilities_json="$(hyprctl -j psd-plugin 2>/dev/null || printf '{}')"
            state_json="$(hyprctl -j psd-plugin-state 2>/dev/null || printf '{"trackedTransforms":["unavailable"]}')"

            if python3 - "$capabilities_json" "$state_json" <<'PY' >/dev/null 2>&1
import json
import sys

capabilities = json.loads(sys.argv[1])
state = json.loads(sys.argv[2])

if capabilities.get("protocolVersion") != 3:
    raise SystemExit(1)
if capabilities.get("lifecycleEventsExperimental") is not True:
    raise SystemExit(1)
if state.get("trackedTransforms") != []:
    raise SystemExit(1)
PY
            then
                reload_ready=1
                break
            fi
            sleep 0.1
        done

        if [[ "$reload_ready" != "1" ]]; then
            echo "PSD live probe: plugin reload handshake did not become ready." >&2
            hyprctl -j plugin list >&2 || true
            exit 1
        fi

        hyprctl dispatch movecursor "$runtime_center_x $runtime_center_y" | grep -qx "ok"
        sleep 0.1
        hyprctl dispatch movecursor "$runtime_edge_x $runtime_edge_y" | grep -qx "ok"

        reload_transform_ready=0
        for _ in $(seq 1 60); do
            layers_json="$(hyprctl -j layers)"
            state_json="$(plugin_state)"

            if python3 - "$layers_json" "$state_json" "$primary_monitor" <<'PY' >/dev/null 2>&1
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
matches = [x for x in state.get("trackedTransforms", []) if x.get("monitor") == monitor]

if f"psd-return-shield:{monitor}" not in namespaces:
    raise SystemExit(1)
if len(matches) != 1 or len(state.get("trackedTransforms", [])) != 1:
    raise SystemExit(1)
if abs(float(matches[0].get("x", 0.0))) < 1.0 and abs(float(matches[0].get("y", 0.0))) < 1.0:
    raise SystemExit(1)
PY
            then
                reload_transform_ready=1
                break
            fi
            sleep 0.1
        done

        if [[ "$reload_transform_ready" != "1" ]]; then
            echo "PSD live probe: shell did not reacquire compositor transform after plugin reload." >&2
            hyprctl -j layers >&2 || true
            plugin_state >&2 || true
            cat "$log_file" >&2 || true
            exit 1
        fi

        echo "PSD live probe: plugin reload event + transform reacquisition PASS"
    fi

    if [[ -n "$hotplug_monitor" ]]; then
        removed_monitor="$hotplug_monitor"
        if ! remove_hotplug_output; then
            echo "PSD live probe: hotplugged output $removed_monitor did not detach cleanly." >&2
            hyprctl -j monitors >&2 || true
            hyprctl -j layers >&2 || true
            exit 1
        fi
        echo "PSD live probe: monitor hot-remove + shell teardown PASS"
    fi

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

if [[ -n "$hotplug_monitor" ]]; then
    removed_monitor="$hotplug_monitor"
    if ! remove_hotplug_output; then
        echo "PSD live probe: hotplugged output $removed_monitor did not detach cleanly." >&2
        exit 1
    fi
    echo "PSD live probe: monitor hot-remove + shell teardown PASS"
fi

echo "PSD live probe: PASS"
