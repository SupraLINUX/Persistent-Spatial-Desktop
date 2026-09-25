#!/usr/bin/env bash
set -euo pipefail

PLUGIN_PATH="${1:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"
CLIENT_PATH="${2:-build/tests/psd-integration-client}"

required_confirmation="I_UNDERSTAND_DISPLAY_MAY_FLICKER"
if [[ "${PSD_HW_CONFIRM:-}" != "$required_confirmation" ]]; then
    cat >&2 <<EOF
PSD NVIDIA hardware probe: explicit opt-in required.

This probe temporarily:
- enables Hyprland direct scanout;
- applies/resets the experimental PSD presentation offset;
- opens a fullscreen test client on the target monitor;
- may make the display flicker while scanout state changes.

Nothing is persisted to the Hyprland config, and cleanup restores the previous
render:direct_scanout value.

Re-run with:
  PSD_HW_CONFIRM=$required_confirmation $0 [plugin-path] [client-path]
EOF
    exit 64
fi

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    echo "PSD NVIDIA hardware probe: must run inside the Hyprland session under test." >&2
    exit 1
fi

for command in hyprctl python3 nvidia-smi readlink basename; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "PSD NVIDIA hardware probe: required command missing: $command" >&2
        exit 1
    fi
done

if [[ ! -e "$PLUGIN_PATH" ]]; then
    echo "PSD NVIDIA hardware probe: plugin not found: $PLUGIN_PATH" >&2
    exit 1
fi
if [[ ! -x "$CLIENT_PATH" ]]; then
    echo "PSD NVIDIA hardware probe: integration client not executable: $CLIENT_PATH" >&2
    exit 1
fi

PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"
CLIENT_PATH="$(realpath "$CLIENT_PATH")"

hyprland_version="$(hyprctl version)"
if ! grep -Eq '(^|[^0-9])0\.53\.3([^0-9]|$)' <<<"$hyprland_version"; then
    echo "PSD NVIDIA hardware probe: expected Hyprland 0.53.3." >&2
    printf '%s\n' "$hyprland_version" >&2
    exit 1
fi

if ! hyprctl systeminfo | grep -q '^Backend: drm$'; then
    echo "PSD NVIDIA hardware probe: Hyprland is not using the DRM backend." >&2
    hyprctl systeminfo >&2 || true
    exit 1
fi

gpu_summary="$(nvidia-smi --query-gpu=name,driver_version,pci.bus_id --format=csv,noheader 2>/dev/null || true)"
if [[ -z "$gpu_summary" ]]; then
    echo "PSD NVIDIA hardware probe: nvidia-smi did not report an NVIDIA GPU." >&2
    exit 1
fi

if [[ ! -d /sys/module/nvidia_drm ]]; then
    echo "PSD NVIDIA hardware probe: nvidia_drm is not loaded." >&2
    exit 1
fi

if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
    nvidia_modeset="$(cat /sys/module/nvidia_drm/parameters/modeset)"
    case "$nvidia_modeset" in
        Y|y|1) ;;
        *)
            echo "PSD NVIDIA hardware probe: nvidia_drm modeset is not enabled: $nvidia_modeset" >&2
            exit 1
            ;;
    esac
fi

monitor_json="$(hyprctl -j monitors)"
target_monitor="${PSD_HW_MONITOR:-}"

if [[ -z "$target_monitor" ]]; then
    target_monitor="$(python3 - "$monitor_json" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
focused = next((item for item in monitors if item.get("focused")), None)
if focused is None:
    raise SystemExit("no focused monitor")
print(focused["name"])
PY
)"
fi

read -r target_id target_vrr target_mirror target_format target_scale target_transform < <(
    python3 - "$monitor_json" "$target_monitor" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next((item for item in monitors if item.get("name") == name), None)
if monitor is None:
    raise SystemExit(f"monitor not found: {name}")

print(
    int(monitor["id"]),
    "true" if bool(monitor.get("vrr", False)) else "false",
    str(monitor.get("mirrorOf", "none")),
    str(monitor.get("currentFormat", "")),
    float(monitor.get("scale", 1.0) or 1.0),
    int(monitor.get("transform", 0) or 0),
)
PY
)

if [[ "$target_mirror" != "none" ]]; then
    echo "PSD NVIDIA hardware probe: mirrored outputs cannot certify direct scanout: mirrorOf=$target_mirror" >&2
    exit 1
fi

drm_connector=""
drm_driver=""
shopt -s nullglob
for candidate in /sys/class/drm/card*-"$target_monitor"; do
    [[ -e "$candidate" ]] || continue
    driver_path="$(readlink -f "$candidate/device/driver" 2>/dev/null || true)"
    [[ -n "$driver_path" ]] || continue
    driver_name="$(basename "$driver_path")"
    drm_connector="$candidate"
    drm_driver="$driver_name"
    break
done
shopt -u nullglob

if [[ -z "$drm_connector" ]]; then
    echo "PSD NVIDIA hardware probe: could not map Hyprland monitor $target_monitor to /sys/class/drm." >&2
    exit 1
fi

case "$drm_driver" in
    nvidia*)
        ;;
    *)
        echo "PSD NVIDIA hardware probe: target connector is not driven by NVIDIA." >&2
        echo "connector=$drm_connector driver=$drm_driver" >&2
        exit 1
        ;;
esac

original_focus="$(python3 - "$monitor_json" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
focused = next((item for item in monitors if item.get("focused")), None)
print(focused["name"] if focused else "")
PY
)"

original_direct_scanout="$(hyprctl -j getoption render:direct_scanout | python3 -c '
import json,sys
data=json.load(sys.stdin)
print(int(data["int"]))
')"

plugin_loaded_by_probe=0
client_pid=""
test_title="psd-hw-scanout-$BASHPID"
direct_scanout_was_enabled=0

cleanup() {
    set +e

    if [[ -n "$client_pid" ]] && kill -0 "$client_pid" >/dev/null 2>&1; then
        kill -TERM "$client_pid" >/dev/null 2>&1 || true
        wait "$client_pid" >/dev/null 2>&1 || true
    fi
    client_pid=""

    hyprctl dispatch plugin:psd:presentation-reset "$target_monitor" >/dev/null 2>&1 || true

    if [[ "$direct_scanout_was_enabled" == "1" ]]; then
        hyprctl keyword render:direct_scanout "$original_direct_scanout" >/dev/null 2>&1 || true
    fi

    if [[ -n "$original_focus" && "$original_focus" != "$target_monitor" ]]; then
        hyprctl dispatch focusmonitor "$original_focus" >/dev/null 2>&1 || true
    fi

    if [[ "$plugin_loaded_by_probe" == "1" ]]; then
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

plugin_loaded="$(hyprctl -j plugin list | python3 -c '
import json,sys
print("true" if any(x.get("name")=="psd-hyprland-plugin" for x in json.load(sys.stdin)) else "false")
')"

if [[ "$plugin_loaded" != "true" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    plugin_loaded_by_probe=1
fi

capabilities="$(hyprctl -j psd-plugin)"
python3 - "$capabilities" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["protocolVersion"] == 3, data
assert data["pluginVersion"] == "0.1.10", data
assert data["dedicatedPresentationOffsetExperimental"] is True, data
assert data["diagnosticStateQueryExperimental"] is True, data
PY

hyprctl dispatch focusmonitor "$target_monitor" | grep -qx "ok"

echo "PSD NVIDIA hardware probe: environment"
echo "  Hyprland target: 0.53.3"
echo "  monitor: $target_monitor id=$target_id scale=$target_scale transform=$target_transform"
echo "  connector: $drm_connector"
echo "  DRM driver: $drm_driver"
echo "  format: $target_format"
echo "  VRR before fullscreen: $target_vrr"
echo "  NVIDIA GPU(s):"
while IFS= read -r gpu; do
    echo "    $gpu"
done <<<"$gpu_summary"

hyprctl keyword render:direct_scanout 1 | grep -qx "ok"
direct_scanout_was_enabled=1

hyprctl dispatch plugin:psd:presentation-reset "$target_monitor" | grep -qx "ok"
hyprctl dispatch plugin:psd:presentation-offset "$target_monitor 96 0" | grep -qx "ok"

pre_fullscreen_offset=0
for _ in $(seq 1 80); do
    state="$(hyprctl -j psd-plugin-state)"
    if python3 - "$state" "$target_monitor" <<'PY' >/dev/null 2>&1
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
entry = next(
    (item for item in state.get("dedicatedPresentationOffsets", [])
     if item.get("monitor") == monitor),
    None,
)
raise SystemExit(
    0 if entry
    and abs(float(entry.get("x", 0.0)) - 96.0) <= 0.01
    and abs(float(entry.get("y", 0.0))) <= 0.01
    else 1
)
PY
    then
        pre_fullscreen_offset=1
        break
    fi
    sleep 0.025
done

if [[ "$pre_fullscreen_offset" != "1" ]]; then
    echo "PSD NVIDIA hardware probe: dedicated offset did not become active before fullscreen." >&2
    hyprctl -j psd-plugin-state >&2 || true
    exit 1
fi

"$CLIENT_PATH" \
    --title "$test_title" \
    --color "#1638f2" \
    --fullscreen \
    >/tmp/psd-hw-direct-scanout-client.log 2>&1 &
client_pid=$!

fullscreen_ready=0
for _ in $(seq 1 160); do
    clients="$(hyprctl -j clients)"
    if python3 - "$clients" "$test_title" "$target_id" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
title = sys.argv[2]
monitor_id = int(sys.argv[3])
client = next((item for item in clients if item.get("title") == title), None)
if client is None:
    raise SystemExit(1)
fullscreen = int(client.get("fullscreen", 0) or 0) != 0
correct_monitor = int(client.get("monitor", -1)) == monitor_id
raise SystemExit(0 if fullscreen and correct_monitor else 1)
PY
    then
        fullscreen_ready=1
        break
    fi
    sleep 0.05
done

if [[ "$fullscreen_ready" != "1" ]]; then
    echo "PSD NVIDIA hardware probe: fullscreen client did not settle on target monitor." >&2
    hyprctl -j clients >&2 || true
    exit 1
fi

fullscreen_reset=0
for _ in $(seq 1 80); do
    state="$(hyprctl -j psd-plugin-state)"
    if python3 - "$state" "$target_monitor" <<'PY' >/dev/null 2>&1
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
entry = next(
    (item for item in state.get("dedicatedPresentationOffsets", [])
     if item.get("monitor") == monitor),
    None,
)
raise SystemExit(0 if entry is None else 1)
PY
    then
        fullscreen_reset=1
        break
    fi
    sleep 0.025
done

if [[ "$fullscreen_reset" != "1" ]]; then
    echo "PSD NVIDIA hardware probe: explicit fullscreen did not clear the PSD dedicated offset." >&2
    hyprctl -j psd-plugin-state >&2 || true
    exit 1
fi

set +e
refused_output="$(hyprctl dispatch plugin:psd:presentation-offset "$target_monitor 96 0" 2>&1)"
refused_status=$?
set -e

if [[ "$refused_output" == "ok" ]] || [[ "$refused_output" != *"refusing dedicated presentation offset while explicit fullscreen content is active"* ]]; then
    echo "PSD NVIDIA hardware probe: fullscreen accepted a PSD offset unexpectedly." >&2
    echo "status=$refused_status output=$refused_output" >&2
    exit 1
fi

scanout_active=0
scanout_to="0"
scanout_blocked="[]"
fullscreen_vrr="false"

for _ in $(seq 1 240); do
    monitor_state="$(hyprctl -j monitors)"
    read -r scanout_to fullscreen_vrr scanout_blocked < <(
        python3 - "$monitor_state" "$target_monitor" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next(item for item in monitors if item.get("name") == name)
blocked = monitor.get("directScanoutBlockedBy")
print(
    str(monitor.get("directScanoutTo", "0")),
    "true" if bool(monitor.get("vrr", False)) else "false",
    json.dumps(blocked, separators=(",", ":")),
)
PY
    )

    if [[ "$scanout_to" != "0" && "$scanout_to" != "0x0" ]]; then
        scanout_active=1
        break
    fi

    sleep 0.05
done

if [[ "$scanout_active" != "1" ]]; then
    echo "PSD NVIDIA hardware probe: REAL DIRECT SCANOUT NOT ACHIEVED." >&2
    echo "  directScanoutTo=$scanout_to" >&2
    echo "  directScanoutBlockedBy=$scanout_blocked" >&2
    echo "This is not a PSD direct-scanout certification." >&2
    echo "Common Hyprland 0.53.3 blockers include USER, RECORD, SW, CANDIDATE, SURFACE, TRANSFORM, DMA, FAILED and CM." >&2
    hyprctl -j monitors >&2 || true
    exit 2
fi

echo "PSD NVIDIA hardware probe: real direct scanout ACTIVE target=$scanout_to blockedBy=$scanout_blocked"
echo "PSD NVIDIA hardware probe: VRR during direct scanout=$fullscreen_vrr"

if [[ "${PSD_HW_REQUIRE_VRR:-1}" == "1" && "$fullscreen_vrr" != "true" ]]; then
    echo "PSD NVIDIA hardware probe: direct scanout passed, but active VRR was required and is false." >&2
    echo "Re-run only after VRR is enabled by the normal Hyprland configuration for this monitor." >&2
    exit 3
fi

# The refused offset must not disturb zero-copy presentation.
sleep 0.15
monitor_state="$(hyprctl -j monitors)"
python3 - "$monitor_state" "$target_monitor" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next(item for item in monitors if item.get("name") == name)
scanout = str(monitor.get("directScanoutTo", "0"))
if scanout in ("0", "0x0"):
    raise SystemExit(
        f"direct scanout disappeared after refused PSD offset: {monitor}"
    )
PY

kill -TERM "$client_pid"
wait "$client_pid" >/dev/null 2>&1 || true
client_pid=""

client_gone=0
scanout_cleared=0
for _ in $(seq 1 160); do
    clients="$(hyprctl -j clients)"
    monitor_state="$(hyprctl -j monitors)"

    if python3 - "$clients" "$test_title" <<'PY' >/dev/null 2>&1
import json
import sys
clients = json.loads(sys.argv[1])
title = sys.argv[2]
raise SystemExit(0 if not any(item.get("title") == title for item in clients) else 1)
PY
    then
        client_gone=1
    fi

    if python3 - "$monitor_state" "$target_monitor" <<'PY' >/dev/null 2>&1
import json
import sys
monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next(item for item in monitors if item.get("name") == name)
scanout = str(monitor.get("directScanoutTo", "0"))
raise SystemExit(0 if scanout in ("0", "0x0") else 1)
PY
    then
        scanout_cleared=1
    fi

    if [[ "$client_gone" == "1" && "$scanout_cleared" == "1" ]]; then
        break
    fi
    sleep 0.05
done

if [[ "$client_gone" != "1" || "$scanout_cleared" != "1" ]]; then
    echo "PSD NVIDIA hardware probe: fullscreen/direct-scanout state did not clear after client exit." >&2
    hyprctl -j monitors >&2 || true
    hyprctl -j clients >&2 || true
    exit 1
fi

state="$(hyprctl -j psd-plugin-state)"
python3 - "$state" "$target_monitor" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
entry = next(
    (item for item in state.get("dedicatedPresentationOffsets", [])
     if item.get("monitor") == monitor),
    None,
)
if entry is not None:
    raise SystemExit(f"stale PSD offset survived fullscreen exit: {entry}")
PY

hyprctl dispatch plugin:psd:presentation-offset "$target_monitor 96 0" | grep -qx "ok"

post_fullscreen_offset=0
for _ in $(seq 1 80); do
    state="$(hyprctl -j psd-plugin-state)"
    if python3 - "$state" "$target_monitor" <<'PY' >/dev/null 2>&1
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
entry = next(
    (item for item in state.get("dedicatedPresentationOffsets", [])
     if item.get("monitor") == monitor),
    None,
)
raise SystemExit(
    0 if entry and abs(float(entry.get("x", 0.0)) - 96.0) <= 0.01 else 1
)
PY
    then
        post_fullscreen_offset=1
        break
    fi
    sleep 0.025
done

if [[ "$post_fullscreen_offset" != "1" ]]; then
    echo "PSD NVIDIA hardware probe: dedicated offset did not recover after fullscreen/direct-scanout exit." >&2
    exit 1
fi

hyprctl dispatch plugin:psd:presentation-reset "$target_monitor" | grep -qx "ok"

echo "PSD NVIDIA hardware probe: fullscreen reset + direct scanout + recovery PASS"
if [[ "$fullscreen_vrr" == "true" ]]; then
    echo "PSD NVIDIA hardware probe: active VRR during real direct scanout PASS"
else
    echo "PSD NVIDIA hardware probe: active VRR NOT validated (PSD_HW_REQUIRE_VRR=0)"
fi
echo "PSD NVIDIA hardware probe: NVIDIA hardware characterization PASS"
