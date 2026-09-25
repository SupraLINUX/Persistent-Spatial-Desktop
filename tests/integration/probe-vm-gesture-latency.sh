#!/usr/bin/env bash
set -euo pipefail

SHELL_PATH="${1:-build/psd-shell}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"
TOUCHPAD_HELPER="${3:-build/tests/psd-uinput-touchpad}"

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    echo "PSD gesture latency probe: must run inside the Hyprland session under test." >&2
    exit 1
fi

for path in "$SHELL_PATH" "$PLUGIN_PATH" "$TOUCHPAD_HELPER"; do
    if [[ ! -e "$path" ]]; then
        echo "PSD gesture latency probe: required path missing: $path" >&2
        exit 1
    fi
done

SHELL_PATH="$(realpath "$SHELL_PATH")"
PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"
TOUCHPAD_HELPER="$(realpath "$TOUCHPAD_HELPER")"

loaded_by_probe=0
shell_pid=""
log_file="${TMPDIR:-/tmp}/psd-gesture-latency-shell.log"

cleanup() {
    set +e

    if [[ -n "$shell_pid" ]] && kill -0 "$shell_pid" >/dev/null 2>&1; then
        kill -TERM "$shell_pid" >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            kill -0 "$shell_pid" >/dev/null 2>&1 || break
            sleep 0.1
        done
        kill -KILL "$shell_pid" >/dev/null 2>&1 || true
        wait "$shell_pid" >/dev/null 2>&1 || true
    fi

    hyprctl dispatch plugin:psd:gesture-events 0 >/dev/null 2>&1 || true

    if [[ "$loaded_by_probe" == "1" ]]; then
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

existing_psd_layer="$(hyprctl -j layers | python3 -c '
import json,sys
layers=json.load(sys.stdin)
print(any(
    str(layer.get("namespace","")).startswith("psd-shell:")
    for monitor in layers.values()
    for level in monitor.get("levels",{}).values()
    for layer in level
    if layer.get("pid",0) != -1
))
')"

if [[ "$existing_psd_layer" == "True" ]]; then
    echo "PSD gesture latency probe: PSD shell is already mapped." >&2
    exit 1
fi

plugin_loaded="$(hyprctl -j plugin list | python3 -c '
import json,sys
print(any(x.get("name")=="psd-hyprland-plugin" for x in json.load(sys.stdin)))
')"

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
assert data["pluginVersion"] == "0.1.10", data
assert data["fourFingerGestureEventsExperimental"] is True, data
assert data["lifecycleEventsExperimental"] is True, data
PY

# Establish a deterministic unarmed baseline. The real shell must arm it.
hyprctl dispatch plugin:psd:gesture-events 0 | grep -qx "ok"

monitor_json="$(hyprctl -j monitors)"
primary_monitor="$(python3 - "$monitor_json" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
focused = next((m for m in monitors if m.get("focused")), monitors[0])
print(focused["name"])
PY
)"

PSD_EXPERIMENTAL_HYPRLAND_SYNC=1 "$SHELL_PATH" >"$log_file" 2>&1 &
shell_pid=$!

auto_arm_ready=0
for _ in $(seq 1 100); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
        echo "PSD gesture latency probe: shell exited before gesture arm." >&2
        cat "$log_file" >&2 || true
        exit 1
    fi

    layers_json="$(hyprctl -j layers)"
    state_json="$(hyprctl -j psd-plugin-state)"

    if python3 - "$layers_json" "$state_json" "$primary_monitor" <<'PY' >/dev/null 2>&1
import json
import sys

layers = json.loads(sys.argv[1])
state = json.loads(sys.argv[2])
monitor = sys.argv[3]

namespaces = [
    layer.get("namespace", "")
    for level in layers.get(monitor, {}).get("levels", {}).values()
    for layer in level
    if layer.get("pid", 0) != -1
]

if namespaces.count(f"psd-shell:{monitor}") != 1:
    raise SystemExit(1)
if state.get("gestureEventsEnabled") is not True:
    raise SystemExit(1)
if state.get("gestureActive") is not False:
    raise SystemExit(1)
PY
    then
        auto_arm_ready=1
        break
    fi

    sleep 0.05
done

if [[ "$auto_arm_ready" != "1" ]]; then
    echo "PSD gesture latency probe: runtime did not automatically arm four-finger gestures." >&2
    hyprctl -j psd-plugin-state >&2 || true
    cat "$log_file" >&2 || true
    exit 1
fi

echo "PSD gesture latency probe: runtime automatic four-finger arm PASS"

if [[ ! -c /dev/uinput ]]; then
    sudo modprobe uinput
fi
if [[ ! -c /dev/uinput ]]; then
    echo "PSD gesture latency probe: /dev/uinput unavailable." >&2
    exit 1
fi

sudo "$TOUCHPAD_HELPER" \
    --fingers 4 \
    --dx 320 \
    --dy 0 \
    --steps 16 \
    --pre-delay-ms 900 \
    --duration-ms 240

latency_ready=0
for _ in $(seq 1 100); do
    state_json="$(hyprctl -j psd-plugin-state)"

    if python3 - "$state_json" "$primary_monitor" <<'PY' >/dev/null 2>&1
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
latency = state.get("gestureLatency")

if not isinstance(latency, dict):
    raise SystemExit(1)
if latency.get("monitor") != monitor:
    raise SystemExit(1)
if int(latency.get("updateCount", 0)) < 1:
    raise SystemExit(1)
if abs(float(latency.get("firstLegacyOffsetX", 0.0))) < 0.01 and \
   abs(float(latency.get("firstLegacyOffsetY", 0.0))) < 0.01:
    raise SystemExit(1)
if int(latency.get("updateToCommandUs", 0)) <= 0:
    raise SystemExit(1)
if int(latency.get("commandToPreRenderUs", 0)) <= 0:
    raise SystemExit(1)
if int(latency.get("updateToPreRenderUs", 0)) <= 0:
    raise SystemExit(1)
PY
    then
        latency_ready=1
        break
    fi

    sleep 0.025
done

if [[ "$latency_ready" != "1" ]]; then
    echo "PSD gesture latency probe: gesture did not traverse shell -> compositor -> preRender." >&2
    hyprctl -j psd-plugin-state >&2 || true
    cat "$log_file" >&2 || true
    exit 1
fi

state_json="$(hyprctl -j psd-plugin-state)"
python3 - "$state_json" "$primary_monitor" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
latency = state["gestureLatency"]

update_to_command = int(latency["updateToCommandUs"])
command_to_frame = int(latency["commandToPreRenderUs"])
update_to_frame = int(latency["updateToPreRenderUs"])

# Characterization guard only. This is intentionally loose until repeated
# physical touchpad/GPU measurements establish a product latency budget.
if update_to_frame > 500_000:
    raise SystemExit(
        f"gesture path exceeded characterization sanity bound: {update_to_frame} us"
    )

print(
    "PSD gesture latency probe: end-to-end characterization PASS "
    f"monitor={monitor} updates={latency['updateCount']} "
    f"firstOffset=({float(latency['firstLegacyOffsetX']):.3f},"
    f"{float(latency['firstLegacyOffsetY']):.3f}) "
    f"hookToCommand={update_to_command/1000.0:.3f}ms "
    f"commandToPreRender={command_to_frame/1000.0:.3f}ms "
    f"hookToPreRender={update_to_frame/1000.0:.3f}ms"
)
PY

# Allow the gesture release/cancel animation to settle before shutdown.
sleep 0.7

kill -TERM "$shell_pid"

shell_exited=0
for _ in $(seq 1 60); do
    if ! kill -0 "$shell_pid" >/dev/null 2>&1; then
        shell_exited=1
        break
    fi
    sleep 0.05
done

if [[ "$shell_exited" != "1" ]]; then
    echo "PSD gesture latency probe: shell did not exit after SIGTERM." >&2
    cat "$log_file" >&2 || true
    exit 1
fi

set +e
wait "$shell_pid"
shell_status=$?
set -e
shell_pid=""

if [[ "$shell_status" -ne 0 ]]; then
    echo "PSD gesture latency probe: shell exited abnormally status=$shell_status" >&2
    echo "===== psd-shell log =====" >&2
    cat "$log_file" >&2 || true
    echo "===== plugin state after shell failure =====" >&2
    hyprctl -j psd-plugin-state >&2 || true
    exit "$shell_status"
fi

disarmed=0
for _ in $(seq 1 60); do
    state_json="$(hyprctl -j psd-plugin-state)"
    if python3 - "$state_json" <<'PY' >/dev/null 2>&1
import json
import sys

state = json.loads(sys.argv[1])
clean = (
    state.get("gestureEventsEnabled") is False
    and state.get("gestureActive") is False
    and state.get("trackedTransforms") == []
)
raise SystemExit(0 if clean else 1)
PY
    then
        disarmed=1
        break
    fi
    sleep 0.05
done

if [[ "$disarmed" != "1" ]]; then
    echo "PSD gesture latency probe: shell shutdown did not disarm gestures cleanly." >&2
    hyprctl -j psd-plugin-state >&2 || true
    cat "$log_file" >&2 || true
    exit 1
fi

echo "PSD gesture latency probe: shutdown gesture disarm PASS"
echo "PSD gesture latency probe: PASS"
