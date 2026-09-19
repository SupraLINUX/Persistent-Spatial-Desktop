#!/usr/bin/env bash
set -euo pipefail

SHELL_PATH="${1:-build/psd-shell}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"

SHELL_PATH="$(realpath "$SHELL_PATH")"
PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    echo "PSD live probe: this must run inside the Hyprland session being tested." >&2
    exit 1
fi

for command in hyprctl python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "PSD live probe: missing command: $command" >&2
        exit 1
    fi
done

if [[ ! -x "$SHELL_PATH" ]]; then
    echo "PSD live probe: shell binary not found/executable: $SHELL_PATH" >&2
    exit 1
fi

if [[ ! -f "$PLUGIN_PATH" ]]; then
    echo "PSD live probe: plugin not found: $PLUGIN_PATH" >&2
    exit 1
fi

existing_shell="$(hyprctl -j layers | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(str(x.get("namespace","")).startswith("psd-shell:") for m in d.values() for level in m.get("levels",{}).values() for x in level))')"
if [[ "$existing_shell" == "True" ]]; then
    echo "PSD live probe: a PSD shell layer is already mapped; refusing to create a duplicate." >&2
    exit 1
fi

loaded_by_probe=0
shell_pid=""
log_file="${TMPDIR:-/tmp}/psd-live-session-probe.log"

cleanup() {
    set +e
    hyprctl dispatch plugin:psd:gesture-events 0 >/dev/null 2>&1 || true

    if [[ -n "$shell_pid" ]]; then
        kill "$shell_pid" >/dev/null 2>&1 || true
        wait "$shell_pid" >/dev/null 2>&1 || true
    fi

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
print("PSD live probe: plugin capability handshake PASS")
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

for monitor in monitors:
    name = monitor["name"]
    expected = f"psd-shell:{name}"
    monitor_layers = layers.get(name, {}).get("levels", {})
    namespaces = {
        layer.get("namespace", "")
        for level in monitor_layers.values()
        for layer in level
    }
    if expected not in namespaces:
        raise SystemExit(1)
PY
    then
        ready=1
        break
    fi

    sleep 0.1
done

if [[ "$ready" != "1" ]]; then
    echo "PSD live probe: not every active monitor received its PSD layer surface." >&2
    hyprctl -j layers >&2 || true
    cat "$log_file" >&2 || true
    exit 1
fi

echo "PSD live probe: $monitor_count monitor-local shell surface(s) PASS"

hyprctl dispatch plugin:psd:gesture-events 1 | grep -qx "ok"
hyprctl dispatch plugin:psd:gesture-events 0 | grep -qx "ok"
echo "PSD live probe: four-finger gesture arm/disarm PASS"

if [[ "${PSD_PROBE_EXERCISE_OFFSET:-0}" == "1" ]]; then
    primary_monitor="$(python3 - "$monitor_json" <<'PY'
import json, sys
monitors = json.loads(sys.argv[1])
focused = next((m for m in monitors if m.get("focused")), monitors[0])
print(focused["name"])
PY
)"

    hyprctl dispatch plugin:psd:offset "$primary_monitor 24 0" | grep -qx "ok"
    sleep 0.15
    hyprctl dispatch plugin:psd:reset "$primary_monitor" | grep -qx "ok"
    echo "PSD live probe: explicit offset/reset on $primary_monitor PASS"
fi

echo "PSD live probe: PASS"
