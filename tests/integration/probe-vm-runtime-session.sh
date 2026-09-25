#!/usr/bin/env bash
set -euo pipefail

SHELL_PATH="${1:-build/psd-shell}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"
CONFIG_PATH="${3:-tests/integration/hyprland-headless.conf}"

for command in Hyprland hyprctl python3 realpath; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "PSD VM runtime probe: missing command: $command" >&2
        exit 1
    fi
done

for path in "$SHELL_PATH" "$PLUGIN_PATH" "$CONFIG_PATH"; do
    if [[ ! -e "$path" ]]; then
        echo "PSD VM runtime probe: required path not found: $path" >&2
        exit 1
    fi
done

SHELL_PATH="$(realpath "$SHELL_PATH")"
PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"
CONFIG_PATH="$(realpath "$CONFIG_PATH")"

if [[ ! -x "$SHELL_PATH" ]]; then
    echo "PSD VM runtime probe: shell binary is not executable: $SHELL_PATH" >&2
    exit 1
fi

if [[ ! -f "$PLUGIN_PATH" || ! -f "$CONFIG_PATH" ]]; then
    echo "PSD VM runtime probe: plugin/config must be regular files" >&2
    exit 1
fi

if ! compgen -G "/dev/dri/renderD*" >/dev/null; then
    echo "PSD VM runtime probe: guest has no DRM render node." >&2
    ls -la /dev/dri >&2 2>/dev/null || true
    exit 77
fi

runtime_dir=""
owns_runtime_dir=0
log_file="${TMPDIR:-/tmp}/psd-hyprland-vm-runtime.log"
hyprland_pid=""
original_monitor_scale=""
original_monitor_transform=""
fractional_plugin_preloaded=0
transform_plugin_preloaded=0
vrr_plugin_preloaded=0
gesture_plugin_preloaded=0

if [[ "${PSD_PROBE_USE_WAYLAND_BACKEND:-0}" == "1" ]]; then
    if [[ -z "${XDG_RUNTIME_DIR:-}" || -z "${WAYLAND_DISPLAY:-}" ]]; then
        echo "PSD VM runtime probe: nested Wayland mode requires XDG_RUNTIME_DIR and WAYLAND_DISPLAY." >&2
        exit 1
    fi

    runtime_dir="$XDG_RUNTIME_DIR"
    unset HYPRLAND_HEADLESS_ONLY
elif [[ "${PSD_PROBE_USE_NATIVE_BACKEND:-0}" == "1" ]]; then
    runtime_dir="$(mktemp -d)"
    owns_runtime_dir=1
    export XDG_RUNTIME_DIR="$runtime_dir"
    chmod 700 "$XDG_RUNTIME_DIR"
    unset HYPRLAND_HEADLESS_ONLY
    unset WAYLAND_DISPLAY
    unset DISPLAY
else
    runtime_dir="$(mktemp -d)"
    owns_runtime_dir=1
    export XDG_RUNTIME_DIR="$runtime_dir"
    chmod 700 "$XDG_RUNTIME_DIR"
    export HYPRLAND_HEADLESS_ONLY=1
fi

cleanup() {
    set +e

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" && -n "${monitor_name:-}" && -n "${original_monitor_scale:-}" && -n "${original_monitor_transform:-}" ]]; then
        hyprctl keyword monitor "$monitor_name,preferred,auto,$original_monitor_scale,transform,$original_monitor_transform" >/dev/null 2>&1 || true
    fi

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" && "$gesture_plugin_preloaded" == "1" ]]; then
        hyprctl dispatch plugin:psd:gesture-events 0 >/dev/null 2>&1 || true
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
        gesture_plugin_preloaded=0
    fi

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" && "$vrr_plugin_preloaded" == "1" ]]; then
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
        vrr_plugin_preloaded=0
    fi

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" && "$transform_plugin_preloaded" == "1" ]]; then
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
        transform_plugin_preloaded=0
    fi

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" && "$fractional_plugin_preloaded" == "1" ]]; then
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
        fractional_plugin_preloaded=0
    fi

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        hyprctl dispatch exit >/dev/null 2>&1 || true
    fi

    if [[ -n "$hyprland_pid" ]]; then
        kill "$hyprland_pid" >/dev/null 2>&1 || true
        wait "$hyprland_pid" >/dev/null 2>&1 || true
    fi

    if [[ "$owns_runtime_dir" == "1" ]]; then
        rm -rf "$runtime_dir"
    fi
}
trap cleanup EXIT

Hyprland --i-am-really-stupid --config "$CONFIG_PATH" >"$log_file" 2>&1 &
hyprland_pid=$!

instance_dir=""
for _ in $(seq 1 120); do
    if ! kill -0 "$hyprland_pid" >/dev/null 2>&1; then
        echo "PSD VM runtime probe: Hyprland exited before IPC became ready." >&2
        cat "$log_file" >&2 || true
        exit 1
    fi

    instance_dir="$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)"
    if [[ -n "$instance_dir" && -S "$instance_dir/.socket.sock" && -S "$instance_dir/.socket2.sock" ]]; then
        break
    fi

    sleep 0.1
done

if [[ -z "$instance_dir" || ! -S "$instance_dir/.socket.sock" ]]; then
    echo "PSD VM runtime probe: Hyprland IPC did not become ready." >&2
    cat "$log_file" >&2 || true

    latest_crash="$(find "${HOME}/.cache/hyprland" -maxdepth 1 -type f -name 'hyprlandCrashReport*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"
    if [[ -n "$latest_crash" && -f "$latest_crash" ]]; then
        echo "===== PSD VM runtime probe: latest Hyprland crash report =====" >&2
        cat "$latest_crash" >&2 || true
    fi

    exit 1
fi

export HYPRLAND_INSTANCE_SIGNATURE="$(basename "$instance_dir")"

monitor_name="$(hyprctl -j monitors | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["name"] if d else "")')"
if [[ -z "$monitor_name" ]]; then
    hyprctl output create headless PSD-VM >/dev/null

    for _ in $(seq 1 50); do
        monitor_name="$(hyprctl -j monitors | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["name"] if d else "")')"
        [[ -n "$monitor_name" ]] && break
        sleep 0.1
    done
fi

if [[ -z "$monitor_name" ]]; then
    echo "PSD VM runtime probe: no Hyprland output became available." >&2
    cat "$log_file" >&2 || true
    exit 1
fi

monitor_json="$(hyprctl -j monitors)"
original_monitor_scale="$(
    python3 - "$monitor_json" "$monitor_name" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next((item for item in monitors if item.get("name") == name), None)
if monitor is None:
    raise SystemExit(1)
print(float(monitor.get("scale", 1.0) or 1.0))
PY
)"

original_monitor_transform="$(
    python3 - "$monitor_json" "$monitor_name" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next((item for item in monitors if item.get("name") == name), None)
if monitor is None:
    raise SystemExit(1)
print(int(monitor.get("transform", 0) or 0))
PY
)"

echo "PSD VM runtime probe: using guest DRM render node(s):"
ls -l /dev/dri/renderD*
echo "PSD VM runtime probe: using Hyprland output $monitor_name scale=$original_monitor_scale"

if [[ "${PSD_PROBE_USE_NATIVE_BACKEND:-0}" == "1" ]]; then
    wayland_socket=""
    for _ in $(seq 1 50); do
        wayland_socket="$(find "$XDG_RUNTIME_DIR" -maxdepth 3 -type s -name 'wayland-*' 2>/dev/null | head -n1 || true)"
        [[ -n "$wayland_socket" ]] && break
        sleep 0.1
    done

    if [[ -z "$wayland_socket" || ! -S "$wayland_socket" ]]; then
        echo "PSD VM runtime probe: Hyprland Wayland socket not found." >&2
        find "$XDG_RUNTIME_DIR" -maxdepth 3 -type s -print >&2 2>/dev/null || true
        cat "$log_file" >&2 || true
        exit 1
    fi

    export WAYLAND_DISPLAY="$wayland_socket"
    export QT_QPA_PLATFORM=wayland
    echo "PSD VM runtime probe: shell Wayland socket $WAYLAND_DISPLAY"
fi


monitor_scale() {
    local monitors_json
    monitors_json="$(hyprctl -j monitors)"
    python3 - "$monitors_json" "$monitor_name" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next((item for item in monitors if item.get("name") == name), None)
if monitor is None:
    raise SystemExit(1)
print(float(monitor.get("scale", 1.0) or 1.0))
PY
}

wait_for_monitor_scale() {
    local expected="$1"

    for _ in $(seq 1 80); do
        local actual
        actual="$(monitor_scale)"
        if python3 - "$actual" "$expected" <<'PY' >/dev/null 2>&1
import sys
actual = float(sys.argv[1])
expected = float(sys.argv[2])
raise SystemExit(0 if abs(actual - expected) <= 0.01 else 1)
PY
        then
            return 0
        fi
        sleep 0.05
    done

    echo "PSD VM runtime probe: monitor $monitor_name did not reach scale=$expected" >&2
    hyprctl -j monitors >&2 || true
    return 1
}

set_monitor_scale() {
    local scale="$1"
    hyprctl keyword monitor "$monitor_name,preferred,auto,$scale" | grep -qx "ok"
    wait_for_monitor_scale "$scale"
}

monitor_transform() {
    local monitors_json
    monitors_json="$(hyprctl -j monitors)"
    python3 - "$monitors_json" "$monitor_name" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next((item for item in monitors if item.get("name") == name), None)
if monitor is None:
    raise SystemExit(1)
print(int(monitor.get("transform", 0) or 0))
PY
}

wait_for_monitor_transform() {
    local expected="$1"

    for _ in $(seq 1 80); do
        local actual
        actual="$(monitor_transform)"
        if [[ "$actual" == "$expected" ]]; then
            return 0
        fi
        sleep 0.05
    done

    echo "PSD VM runtime probe: monitor $monitor_name did not reach transform=$expected" >&2
    hyprctl -j monitors >&2 || true
    return 1
}

set_monitor_transform() {
    local transform="$1"
    local scale
    scale="$(monitor_scale)"

    # Hyprland 0.53.3's special "<name>,transform,<n>" parser path updates the
    # stored rule but returns before applying/reloading the output. Use a full
    # monitor rule so mode/position/scale/transform are committed immediately.
    hyprctl keyword monitor "$monitor_name,preferred,auto,$scale,transform,$transform" | grep -qx "ok"
    wait_for_monitor_transform "$transform"
}

monitor_vrr_state() {
    local monitors_json
    monitors_json="$(hyprctl -j monitors)"
    python3 - "$monitors_json" "$monitor_name" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next((item for item in monitors if item.get("name") == name), None)
if monitor is None:
    raise SystemExit(1)
print("true" if bool(monitor.get("vrr", False)) else "false")
PY
}

plugin_state_counter() {
    local field="$1"
    local state
    state="$(hyprctl -j psd-plugin-state)"
    python3 - "$state" "$field" "$monitor_name" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
field = sys.argv[2]
monitor = sys.argv[3]
entry = next(
    (item for item in state.get(field, []) if item.get("monitor") == monitor),
    None,
)
print(int(entry.get("count", 0)) if entry else 0)
PY
}

wait_plugin_counter_after() {
    local field="$1"
    local before="$2"
    local label="$3"

    for _ in $(seq 1 80); do
        local now
        now="$(plugin_state_counter "$field")"
        if (( now > before )); then
            echo "PSD VM runtime probe: $label PASS count=$before->$now"
            return 0
        fi
        sleep 0.05
    done

    echo "PSD VM runtime probe: $label did not advance field=$field before=$before" >&2
    hyprctl -j psd-plugin-state >&2 || true
    return 1
}

wait_plugin_counter_quiet() {
    local field="$1"
    local label="$2"

    for _ in $(seq 1 30); do
        local before
        local after
        before="$(plugin_state_counter "$field")"
        sleep 0.10
        after="$(plugin_state_counter "$field")"
        if [[ "$after" == "$before" ]]; then
            echo "PSD VM runtime probe: $label PASS count=$after"
            return 0
        fi
    done

    echo "PSD VM runtime probe: $label never became quiet field=$field" >&2
    hyprctl -j psd-plugin-state >&2 || true
    return 1
}

apply_monitor_vrr_rule() {
    local requested="$1"
    local scale
    local transform
    scale="$(monitor_scale)"
    transform="$(monitor_transform)"
    hyprctl keyword monitor "$monitor_name,preferred,auto,$scale,transform,$transform,vrr,$requested" | grep -qx "ok"
}

restore_monitor_rule_without_vrr_override() {
    local scale
    local transform
    scale="$(monitor_scale)"
    transform="$(monitor_transform)"
    hyprctl keyword monitor "$monitor_name,preferred,auto,$scale,transform,$transform" | grep -qx "ok"
}

set_fractional_monitor_scale() {
    local requested="$1"

    hyprctl keyword monitor "$monitor_name,preferred,auto,$requested" | grep -qx "ok"

    for _ in $(seq 1 80); do
        local actual
        actual="$(monitor_scale)"

        if python3 - "$actual" "$original_monitor_scale" <<'PY' >/dev/null 2>&1
import math
import sys

actual = float(sys.argv[1])
original = float(sys.argv[2])

changed = abs(actual - original) > 0.01
fractional = abs(actual - round(actual)) > 0.01
raise SystemExit(0 if changed and fractional else 1)
PY
        then
            echo "$actual"
            return 0
        fi

        sleep 0.05
    done

    echo "PSD VM runtime probe: monitor $monitor_name did not settle on a fractional scale after request=$requested" >&2
    hyprctl -j monitors >&2 || true
    return 1
}

test_client_path="${PSD_PROBE_TEST_CLIENT:-build/tests/psd-integration-client}"
touchpad_helper_path="${PSD_PROBE_TOUCHPAD_HELPER:-build/tests/psd-uinput-touchpad}"

if [[ ! -x "$test_client_path" ]]; then
    echo "PSD VM runtime probe: integration test client not found: $test_client_path" >&2
    exit 1
fi

if [[ ! -x "$touchpad_helper_path" ]]; then
    echo "PSD VM runtime probe: uinput touchpad helper not found: $touchpad_helper_path" >&2
    exit 1
fi

PSD_RENDER_PROBE_BACKEND=legacy \
    bash "$(dirname "$0")/probe-vm-render-transform.sh" "$test_client_path" "$PLUGIN_PATH"
PSD_RENDER_PROBE_BACKEND=dedicated \
    bash "$(dirname "$0")/probe-vm-render-transform.sh" "$test_client_path" "$PLUGIN_PATH"

echo "PSD VM runtime probe: fractional-scale characterization begin requested=1.5"

plugin_loaded="$(hyprctl -j plugin list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(x.get("name")=="psd-hyprland-plugin" for x in d))')"
if [[ "$plugin_loaded" != "True" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    fractional_plugin_preloaded=1
fi
echo "PSD VM runtime probe: fractional plugin preloaded=$fractional_plugin_preloaded"

# Apply fractional scale only after plugin load/config side effects have
# settled. Both child probes then reuse the already-loaded plugin.
fractional_scale="$(set_fractional_monitor_scale 1.5)"
echo "PSD VM runtime probe: fractional-scale effective=$fractional_scale"

PSD_RENDER_PROBE_BACKEND=legacy \
    bash "$(dirname "$0")/probe-vm-render-transform.sh" "$test_client_path" "$PLUGIN_PATH"
echo "PSD VM runtime probe: fractional legacy control PASS effective=$fractional_scale"

PSD_RENDER_PROBE_BACKEND=dedicated \
    bash "$(dirname "$0")/probe-vm-render-transform.sh" "$test_client_path" "$PLUGIN_PATH"

echo "PSD VM runtime probe: fractional-scale characterization PASS effective=$fractional_scale"

set_monitor_scale "$original_monitor_scale"
echo "PSD VM runtime probe: monitor scale restored to $original_monitor_scale"

if [[ "$fractional_plugin_preloaded" == "1" ]]; then
    hyprctl plugin unload "$PLUGIN_PATH" | grep -qx "ok"
    fractional_plugin_preloaded=0
    echo "PSD VM runtime probe: fractional plugin unloaded"
fi

echo "PSD VM runtime probe: monitor-transform matrix characterization begin transforms=1..7"

plugin_loaded="$(hyprctl -j plugin list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(x.get("name")=="psd-hyprland-plugin" for x in d))')"
if [[ "$plugin_loaded" != "True" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    transform_plugin_preloaded=1
fi

for transform in 1 2 3 4 5 6 7; do
    set_monitor_transform "$transform"
    echo "PSD VM runtime probe: monitor transform effective=$transform"

    PSD_RENDER_PROBE_BACKEND=dedicated \
    PSD_RENDER_PROBE_TRANSFORM_ONLY=1 \
        bash "$(dirname "$0")/probe-vm-render-transform.sh" "$test_client_path" "$PLUGIN_PATH"

    echo "PSD VM runtime probe: monitor-transform characterization PASS transform=$transform"
done

set_monitor_transform "$original_monitor_transform"
echo "PSD VM runtime probe: monitor transform restored to $original_monitor_transform"

if [[ "$transform_plugin_preloaded" == "1" ]]; then
    hyprctl plugin unload "$PLUGIN_PATH" | grep -qx "ok"
    transform_plugin_preloaded=0
    echo "PSD VM runtime probe: transform plugin unloaded"
fi

echo "PSD VM runtime probe: monitor-transform matrix characterization PASS transforms=1..7"

echo "PSD VM runtime probe: VRR compatibility characterization begin"

plugin_loaded="$(hyprctl -j plugin list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(x.get("name")=="psd-hyprland-plugin" for x in d))')"
if [[ "$plugin_loaded" != "True" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    vrr_plugin_preloaded=1
fi

hyprctl dispatch plugin:psd:presentation-reset "$monitor_name" | grep -qx "ok"

original_vrr_state="$(monitor_vrr_state)"
apply_monitor_vrr_rule 1

# The QEMU virtio DRM output may reject adaptive sync. Give Hyprland time to
# test/commit the requested state, then record the actual output state rather
# than assuming capability.
sleep 0.25
requested_vrr_state="$(monitor_vrr_state)"
echo "PSD VM runtime probe: VRR request=1 active=$requested_vrr_state original=$original_vrr_state"

wait_plugin_counter_quiet "monitorRenderCounts" "VRR baseline render quiet"

vrr_damage_before="$(plugin_state_counter "dedicatedDamageRequests")"
vrr_render_before="$(plugin_state_counter "monitorRenderCounts")"

hyprctl dispatch plugin:psd:presentation-offset "$monitor_name 96 0" | grep -qx "ok"

wait_plugin_counter_after     "dedicatedDamageRequests" "$vrr_damage_before" "VRR apply damage request"
wait_plugin_counter_after     "monitorRenderCounts" "$vrr_render_before" "VRR apply compositor frame"
wait_plugin_counter_quiet "dedicatedDamageRequests" "VRR apply damage quiet"
wait_plugin_counter_quiet "monitorRenderCounts" "VRR apply render quiet"

vrr_during_offset="$(monitor_vrr_state)"
if [[ "$vrr_during_offset" != "$requested_vrr_state" ]]; then
    echo "PSD VM runtime probe: PSD offset changed VRR state unexpectedly: before=$requested_vrr_state during=$vrr_during_offset" >&2
    exit 1
fi

vrr_damage_before_reset="$(plugin_state_counter "dedicatedDamageRequests")"
vrr_render_before_reset="$(plugin_state_counter "monitorRenderCounts")"

hyprctl dispatch plugin:psd:presentation-reset "$monitor_name" | grep -qx "ok"

wait_plugin_counter_after     "dedicatedDamageRequests" "$vrr_damage_before_reset" "VRR reset damage request"
wait_plugin_counter_after     "monitorRenderCounts" "$vrr_render_before_reset" "VRR reset compositor frame"
wait_plugin_counter_quiet "dedicatedDamageRequests" "VRR reset damage quiet"
wait_plugin_counter_quiet "monitorRenderCounts" "VRR reset render quiet"

vrr_after_reset="$(monitor_vrr_state)"
if [[ "$vrr_after_reset" != "$requested_vrr_state" ]]; then
    echo "PSD VM runtime probe: PSD reset changed VRR state unexpectedly: before=$requested_vrr_state after=$vrr_after_reset" >&2
    exit 1
fi

restore_monitor_rule_without_vrr_override
sleep 0.25
restored_vrr_state="$(monitor_vrr_state)"
if [[ "$restored_vrr_state" != "$original_vrr_state" ]]; then
    echo "PSD VM runtime probe: VRR state did not restore: original=$original_vrr_state restored=$restored_vrr_state" >&2
    exit 1
fi

if [[ "$vrr_plugin_preloaded" == "1" ]]; then
    hyprctl plugin unload "$PLUGIN_PATH" | grep -qx "ok"
    vrr_plugin_preloaded=0
    echo "PSD VM runtime probe: VRR plugin unloaded"
fi

echo "PSD VM runtime probe: VRR compatibility characterization PASS active=$requested_vrr_state"

echo "PSD VM runtime probe: four-finger touchpad integration begin"

if [[ ! -c /dev/uinput ]]; then
    sudo modprobe uinput
fi
if [[ ! -c /dev/uinput ]]; then
    echo "PSD VM runtime probe: /dev/uinput unavailable after modprobe." >&2
    exit 1
fi

plugin_loaded="$(hyprctl -j plugin list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(x.get("name")=="psd-hyprland-plugin" for x in d))')"
if [[ "$plugin_loaded" != "True" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    gesture_plugin_preloaded=1
fi

hyprctl dispatch plugin:psd:gesture-events 1 | grep -qx "ok"

gesture_state="$(hyprctl -j psd-plugin-state)"
python3 - "$gesture_state" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
assert state.get("gestureEventsEnabled") is True, state
assert state.get("gestureActive") is False, state
PY

gesture_socket="$instance_dir/.socket2.sock"
if [[ ! -S "$gesture_socket" ]]; then
    echo "PSD VM runtime probe: Hyprland event socket missing: $gesture_socket" >&2
    exit 1
fi

gesture_listener_pid=""

capture_gesture_events() {
    local output_path="$1"
    local ready_path="$2"
    local timeout_ms="$3"

    rm -f "$output_path" "$ready_path"

    python3 - "$gesture_socket" "$output_path" "$ready_path" "$timeout_ms" <<'PY' &
import select
import socket
import sys
import time

socket_path, output_path, ready_path = sys.argv[1:4]
timeout_ms = int(sys.argv[4])
deadline = time.monotonic() + timeout_ms / 1000.0

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(socket_path)
sock.setblocking(False)

with open(ready_path, "w", encoding="utf-8") as ready:
    ready.write("ready\n")

buffer = b""
with open(output_path, "w", encoding="utf-8") as output:
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        readable, _, _ = select.select([sock], [], [], min(0.1, remaining))
        if not readable:
            continue

        chunk = sock.recv(65536)
        if not chunk:
            break

        buffer += chunk
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            line = raw.decode("utf-8", errors="replace").strip()
            if line.startswith("psdgesture"):
                output.write(line + "\n")
                output.flush()

sock.close()
PY

    gesture_listener_pid=$!

    for _ in $(seq 1 50); do
        if [[ -f "$ready_path" ]]; then
            return 0
        fi
        if ! kill -0 "$gesture_listener_pid" >/dev/null 2>&1; then
            wait "$gesture_listener_pid" || true
            echo "PSD VM runtime probe: gesture event listener exited before ready." >&2
            return 1
        fi
        sleep 0.05
    done

    echo "PSD VM runtime probe: gesture event listener did not become ready." >&2
    kill "$gesture_listener_pid" >/dev/null 2>&1 || true
    wait "$gesture_listener_pid" >/dev/null 2>&1 || true
    return 1
}

three_events="$runtime_dir/psd-three-finger-events.log"
three_ready="$runtime_dir/psd-three-finger-events.ready"
capture_gesture_events "$three_events" "$three_ready" 2600
three_listener_pid="$gesture_listener_pid"

sudo "$touchpad_helper_path" \
    --fingers 3 \
    --dx 240 \
    --dy 0 \
    --steps 12 \
    --pre-delay-ms 900 \
    --duration-ms 180

wait "$three_listener_pid"

if [[ -s "$three_events" ]]; then
    echo "PSD VM runtime probe: three-finger swipe emitted PSD gesture events unexpectedly." >&2
    cat "$three_events" >&2
    exit 1
fi

three_state="$(hyprctl -j psd-plugin-state)"
python3 - "$three_state" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
assert state.get("gestureActive") is False, state
PY
echo "PSD VM runtime probe: three-finger swipe not claimed by PSD PASS"

four_events="$runtime_dir/psd-four-finger-events.log"
four_ready="$runtime_dir/psd-four-finger-events.ready"
capture_gesture_events "$four_events" "$four_ready" 4200
four_listener_pid="$gesture_listener_pid"

sudo "$touchpad_helper_path" \
    --fingers 4 \
    --dx 320 \
    --dy 0 \
    --steps 16 \
    --pre-delay-ms 900 \
    --duration-ms 240

wait "$four_listener_pid"

python3 - "$four_events" "$monitor_name" <<'PY'
import sys

path, expected_monitor = sys.argv[1:3]

with open(path, encoding="utf-8") as handle:
    lines = [line.strip() for line in handle if line.strip()]

begins = []
updates = []
ends = []

for line in lines:
    if ">>" not in line:
        continue

    event, payload = line.split(">>", 1)
    fields = payload.split(",")

    if event == "psdgesturebegin":
        if len(fields) != 2:
            raise SystemExit(f"bad begin payload: {line}")
        begins.append((fields[0], int(fields[1])))
    elif event == "psdgestureupdate":
        if len(fields) != 4:
            raise SystemExit(f"bad update payload: {line}")
        updates.append((fields[0], float(fields[1]), float(fields[2]), int(fields[3])))
    elif event == "psdgestureend":
        if len(fields) != 3:
            raise SystemExit(f"bad end payload: {line}")
        ends.append((fields[0], int(fields[1]), int(fields[2])))

if len(begins) != 1:
    raise SystemExit(f"expected exactly one begin, got {begins}; all={lines}")
if len(ends) != 1:
    raise SystemExit(f"expected exactly one end, got {ends}; all={lines}")
if not updates:
    raise SystemExit(f"expected at least one update; all={lines}")

begin_monitor, begin_time = begins[0]
end_monitor, cancelled, end_time = ends[0]

if begin_monitor != expected_monitor or end_monitor != expected_monitor:
    raise SystemExit(f"gesture monitor mismatch: begin={begins[0]} end={ends[0]}")
if cancelled != 0:
    raise SystemExit(f"four-finger gesture ended cancelled: {ends[0]}")
if end_time < begin_time:
    raise SystemExit(f"gesture timestamps reversed: begin={begin_time} end={end_time}")

update_times = [item[3] for item in updates]
if update_times != sorted(update_times):
    raise SystemExit(f"update timestamps are not monotonic: {update_times}")
if update_times[0] < begin_time or update_times[-1] > end_time:
    raise SystemExit(
        f"update timestamps outside begin/end: begin={begin_time} updates={update_times} end={end_time}"
    )

if any(item[0] != expected_monitor for item in updates):
    raise SystemExit(f"update monitor mismatch: {updates}")

sum_dx = sum(item[1] for item in updates)
sum_dy = sum(item[2] for item in updates)
if abs(sum_dx) <= max(1.0, abs(sum_dy) * 2.0):
    raise SystemExit(
        f"gesture was not predominantly horizontal: dx={sum_dx:.4f} dy={sum_dy:.4f}"
    )

print(
    "PSD VM runtime probe: four-finger event sequence PASS "
    f"updates={len(updates)} cumulativeDelta=({sum_dx:.3f},{sum_dy:.3f}) "
    f"time={begin_time}->{end_time}"
)
PY

four_state="$(hyprctl -j psd-plugin-state)"
python3 - "$four_state" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
assert state.get("gestureEventsEnabled") is True, state
assert state.get("gestureActive") is False, state
PY

hyprctl dispatch plugin:psd:gesture-events 0 | grep -qx "ok"

if [[ "$gesture_plugin_preloaded" == "1" ]]; then
    hyprctl plugin unload "$PLUGIN_PATH" | grep -qx "ok"
    gesture_plugin_preloaded=0
    echo "PSD VM runtime probe: gesture plugin unloaded"
fi

echo "PSD VM runtime probe: four-finger touchpad integration PASS"

bash "$(dirname "$0")/probe-vm-workspace-animation.sh" "$test_client_path" "$PLUGIN_PATH"

PSD_PROBE_TEST_CLIENT="$test_client_path" \
PSD_PROBE_EXERCISE_HOTPLUG=1 \
PSD_PROBE_EXERCISE_CRASH_RECOVERY=1 \
PSD_PROBE_EXERCISE_PLUGIN_LIFECYCLE=1 \
PSD_PROBE_EXERCISE_RUNTIME=1 \
    bash "$(dirname "$0")/probe-live-session.sh" "$SHELL_PATH" "$PLUGIN_PATH"

echo "PSD VM runtime probe: PASS"
