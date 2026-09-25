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
    hyprctl keyword monitor "$monitor_name,transform,$transform" | grep -qx "ok"
    wait_for_monitor_transform "$transform"
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
if [[ ! -x "$test_client_path" ]]; then
    echo "PSD VM runtime probe: integration test client not found: $test_client_path" >&2
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

echo "PSD VM runtime probe: monitor-transform characterization begin transform=1"

plugin_loaded="$(hyprctl -j plugin list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(x.get("name")=="psd-hyprland-plugin" for x in d))')"
if [[ "$plugin_loaded" != "True" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    transform_plugin_preloaded=1
fi

set_monitor_transform 1
echo "PSD VM runtime probe: monitor transform effective=1"

PSD_RENDER_PROBE_BACKEND=dedicated \
PSD_RENDER_PROBE_TRANSFORM_ONLY=1 \
    bash "$(dirname "$0")/probe-vm-render-transform.sh" "$test_client_path" "$PLUGIN_PATH"

set_monitor_transform "$original_monitor_transform"
echo "PSD VM runtime probe: monitor transform restored to $original_monitor_transform"

if [[ "$transform_plugin_preloaded" == "1" ]]; then
    hyprctl plugin unload "$PLUGIN_PATH" | grep -qx "ok"
    transform_plugin_preloaded=0
    echo "PSD VM runtime probe: transform plugin unloaded"
fi

echo "PSD VM runtime probe: monitor-transform characterization PASS transform=1"

bash "$(dirname "$0")/probe-vm-workspace-animation.sh" "$test_client_path" "$PLUGIN_PATH"

PSD_PROBE_TEST_CLIENT="$test_client_path" \
PSD_PROBE_EXERCISE_HOTPLUG=1 \
PSD_PROBE_EXERCISE_CRASH_RECOVERY=1 \
PSD_PROBE_EXERCISE_PLUGIN_LIFECYCLE=1 \
PSD_PROBE_EXERCISE_RUNTIME=1 \
    bash "$(dirname "$0")/probe-live-session.sh" "$SHELL_PATH" "$PLUGIN_PATH"

echo "PSD VM runtime probe: PASS"
