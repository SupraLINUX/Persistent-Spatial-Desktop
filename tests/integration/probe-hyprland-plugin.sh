#!/usr/bin/env bash
set -euo pipefail

PLUGIN_PATH="${1:-build-plugin/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"
CONFIG_PATH="${2:-tests/integration/hyprland-headless.conf}"

if [[ ! -e "$PLUGIN_PATH" ]]; then
    echo "PSD probe: plugin not found: $PLUGIN_PATH" >&2
    exit 1
fi

if [[ ! -e "$CONFIG_PATH" ]]; then
    echo "PSD probe: config not found: $CONFIG_PATH" >&2
    exit 1
fi

PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"
CONFIG_PATH="$(realpath "$CONFIG_PATH")"

if [[ ! -f "$PLUGIN_PATH" ]]; then
    echo "PSD probe: plugin path is not a regular file: $PLUGIN_PATH" >&2
    exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "PSD probe: config path is not a regular file: $CONFIG_PATH" >&2
    exit 1
fi

if ! compgen -G "/dev/dri/renderD*" >/dev/null; then
    echo "PSD probe: no DRM render node is available." >&2
    echo "Aquamarine 0.10 requires a DRM-backed allocator even for the headless output backend." >&2
    echo "Run this probe on a real/self-hosted Linux system exposing /dev/dri/renderD*." >&2
    exit 77
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$(mktemp -d)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

LOG_FILE="${TMPDIR:-/tmp}/psd-hyprland-headless.log"
export HYPRLAND_HEADLESS_ONLY=1
Hyprland --i-am-really-stupid --config "$CONFIG_PATH" >"$LOG_FILE" 2>&1 &
HYPRLAND_PID=$!

cleanup() {
    set +e
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        hyprctl dispatch exit >/dev/null 2>&1 || true
    fi
    kill "$HYPRLAND_PID" >/dev/null 2>&1 || true
    wait "$HYPRLAND_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

instance_dir=""
for _ in $(seq 1 100); do
    instance_dir="$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)"
    if [[ -n "$instance_dir" && -S "$instance_dir/.socket.sock" ]]; then
        break
    fi
    sleep 0.1
done

if [[ -z "$instance_dir" || ! -S "$instance_dir/.socket.sock" ]]; then
    echo "PSD probe: Hyprland IPC did not become ready" >&2
    cat "$LOG_FILE" >&2 || true
    exit 1
fi

export HYPRLAND_INSTANCE_SIGNATURE="$(basename "$instance_dir")"

monitor_name="$(hyprctl -j monitors | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["name"] if d else "")')"
if [[ -z "$monitor_name" ]]; then
    hyprctl output create headless PSD-CI >/dev/null
    for _ in $(seq 1 50); do
        monitor_name="$(hyprctl -j monitors | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["name"] if d else "")')"
        [[ -n "$monitor_name" ]] && break
        sleep 0.1
    done
fi

if [[ -z "$monitor_name" ]]; then
    echo "PSD probe: no headless monitor became available" >&2
    cat "$LOG_FILE" >&2 || true
    exit 1
fi

echo "PSD probe: using monitor $monitor_name"
hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"

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
print("PSD probe: capability handshake PASS")
PY

initial_state="$(hyprctl -j psd-plugin-state)"
python3 - "$initial_state" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["trackedTransforms"] == [], data
PY

hyprctl dispatch plugin:psd:offset "$monitor_name 64 0" | grep -qx "ok"

offset_state="$(hyprctl -j psd-plugin-state)"
python3 - "$offset_state" "$monitor_name" <<'PY'
import json
import math
import sys

data = json.loads(sys.argv[1])
monitor = sys.argv[2]
matches = [x for x in data["trackedTransforms"] if x["monitor"] == monitor]
assert len(matches) == 1, data
transform = matches[0]
assert math.isclose(transform["x"], 64.0, abs_tol=0.01), transform
assert math.isclose(transform["y"], 0.0, abs_tol=0.01), transform
assert transform["workspaceGeneration"] > 0, transform
PY

hyprctl dispatch plugin:psd:reset "$monitor_name" | grep -qx "ok"

reset_state="$(hyprctl -j psd-plugin-state)"
python3 - "$reset_state" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["trackedTransforms"] == [], data
PY

echo "PSD probe: monitor-scoped offset/state/reset PASS"

hyprctl dispatch plugin:psd:gesture-events 1 | grep -qx "ok"
hyprctl dispatch plugin:psd:gesture-events 0 | grep -qx "ok"
echo "PSD probe: gesture arm/disarm PASS"

hyprctl plugin unload "$PLUGIN_PATH" | grep -qx "ok"
echo "PSD probe: plugin unload PASS"
