#!/usr/bin/env bash
set -euo pipefail

CLIENT_PATH="${1:-build/tests/psd-integration-client}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"

for command in grim hyprctl python3 realpath; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "PSD render probe: missing command: $command" >&2
        exit 1
    fi
done

python3 - <<'PY'
from PIL import Image
print("PSD render probe: Pillow screenshot analysis available")
PY

for path in "$CLIENT_PATH" "$PLUGIN_PATH"; do
    if [[ ! -e "$path" ]]; then
        echo "PSD render probe: required path not found: $path" >&2
        exit 1
    fi
done

CLIENT_PATH="$(realpath "$CLIENT_PATH")"
PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"

if [[ ! -x "$CLIENT_PATH" || ! -f "$PLUGIN_PATH" ]]; then
    echo "PSD render probe: invalid client/plugin artifact" >&2
    exit 1
fi

monitor_json="$(hyprctl -j monitors)"
read -r monitor_name monitor_x monitor_y monitor_width monitor_height monitor_scale monitor_transform original_workspace < <(
    python3 - "$monitor_json" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
if not monitors:
    raise SystemExit("no active monitor")

monitor = next((item for item in monitors if item.get("focused")), monitors[0])
workspace = monitor.get("activeWorkspace", {})
workspace_name = str(workspace.get("name", "")).strip()
if not workspace_name:
    raise SystemExit("monitor has no active workspace")

print(
    monitor["name"],
    int(monitor.get("x", 0)),
    int(monitor.get("y", 0)),
    int(monitor["width"]),
    int(monitor["height"]),
    float(monitor.get("scale", 1.0) or 1.0),
    int(monitor.get("transform", 0) or 0),
    workspace_name,
)
PY
)

if [[ "$monitor_transform" != "0" ]]; then
    echo "PSD render probe: VM pixel validation currently requires transform=0, got $monitor_transform" >&2
    exit 1
fi

original_workspace_selector="$original_workspace"
if [[ ! "$original_workspace" =~ ^[0-9]+$ ]]; then
    original_workspace_selector="name:$original_workspace"
fi

work_dir="$(mktemp -d)"
probe_workspace="psd-render-probe-$$"
owns_plugin=0
client_pids=()

cleanup() {
    set +e

    hyprctl dispatch plugin:psd:reset "$monitor_name" >/dev/null 2>&1 || true

    for pid in "${client_pids[@]}"; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done

    hyprctl dispatch focusmonitor "$monitor_name" >/dev/null 2>&1 || true
    hyprctl dispatch workspace "$original_workspace_selector" >/dev/null 2>&1 || true

    if [[ "$owns_plugin" == "1" ]]; then
        hyprctl plugin unload "$PLUGIN_PATH" >/dev/null 2>&1 || true
    fi

    rm -rf "$work_dir"
}
trap cleanup EXIT

plugin_loaded="$(hyprctl -j plugin list | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(x.get("name")=="psd-hyprland-plugin" for x in d))')"
if [[ "$plugin_loaded" != "True" ]]; then
    hyprctl plugin load "$PLUGIN_PATH" | grep -qx "ok"
    owns_plugin=1
fi

capabilities="$(hyprctl -j psd-plugin)"
python3 - "$capabilities" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["protocolVersion"] == 3, data
assert data["spatialRenderOffsetExperimental"] is True, data
assert data["monitorTargeting"] is True, data
print("PSD render probe: plugin capability handshake PASS")
PY

hyprctl dispatch focusmonitor "$monitor_name" | grep -qx "ok"
hyprctl dispatch workspace "name:$probe_workspace" | grep -qx "ok"

wait_for_client() {
    local title="$1"
    local expected_floating="$2"
    local expected_pinned="$3"

    for _ in $(seq 1 60); do
        local clients_json
        clients_json="$(hyprctl -j clients)"
        if python3 - "$clients_json" "$title" "$expected_floating" "$expected_pinned" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
title = sys.argv[2]
floating = sys.argv[3] == "1"
pinned = sys.argv[4] == "1"

client = next((item for item in clients if item.get("title") == title), None)
if client is None:
    raise SystemExit(1)
if bool(client.get("floating", False)) != floating:
    raise SystemExit(1)
if bool(client.get("pinned", False)) != pinned:
    raise SystemExit(1)
PY
        then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

wait_for_client_gone() {
    local title="$1"
    for _ in $(seq 1 60); do
        local clients_json
        clients_json="$(hyprctl -j clients)"
        if python3 - "$clients_json" "$title" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
title = sys.argv[2]
raise SystemExit(0 if all(item.get("title") != title for item in clients) else 1)
PY
        then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

client_geometry() {
    local title="$1"
    hyprctl -j clients | python3 -c '
import json,sys
title=sys.argv[1]
clients=json.load(sys.stdin)
client=next((item for item in clients if item.get("title")==title), None)
if client is None:
    raise SystemExit(1)
at=client.get("at", [0,0])
size=client.get("size", [0,0])
print(f"{int(at[0])},{int(at[1])},{int(size[0])},{int(size[1])}")
' "$title"
}

capture_output() {
    local path="$1"
    grim -o "$monitor_name" "$path"
    [[ -s "$path" ]]
}

assert_pixel_translation() {
    local baseline="$1"
    local candidate="$2"
    local expected_dx="$3"
    local label="$4"

    python3 - "$baseline" "$candidate" "$expected_dx" "$label" <<'PY'
from PIL import Image
import sys

baseline_path, candidate_path = sys.argv[1], sys.argv[2]
expected_dx = int(sys.argv[3])
label = sys.argv[4]
target = (22, 242, 122)
step = 2

def points(path):
    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixels = image.load()
    result = set()

    for y in range(0, height, step):
        for x in range(0, width, step):
            r, g, b = pixels[x, y]
            if (
                abs(r - target[0]) <= 3
                and abs(g - target[1]) <= 3
                and abs(b - target[2]) <= 3
            ):
                result.add((x, y))

    if len(result) < 1000:
        raise SystemExit(
            f"{label}: too few target pixels ({len(result)}) in {path}"
        )
    return result

baseline = points(baseline_path)
candidate = points(candidate_path)

best_dx = None
best_overlap = -1

for dx in range(-160, 161, step):
    overlap = sum((x + dx, y) in candidate for x, y in baseline)
    if overlap > best_overlap:
        best_overlap = overlap
        best_dx = dx

overlap_ratio = best_overlap / max(1, min(len(baseline), len(candidate)))

if abs(best_dx - expected_dx) > 4:
    raise SystemExit(
        f"{label}: expected pixel translation {expected_dx}, "
        f"best correlation was {best_dx} (overlap={overlap_ratio:.3f})"
    )

if overlap_ratio < 0.72:
    raise SystemExit(
        f"{label}: weak translated-mask correlation "
        f"{overlap_ratio:.3f} at dx={best_dx}"
    )

print(
    f"PSD render probe: {label} pixel translation "
    f"{best_dx}px (overlap={overlap_ratio:.3f}) PASS"
)
PY
}

run_case() {
    local mode="$1"
    local target_title="psd-render-$mode-$$"
    local anchor_title="psd-render-$mode-anchor-$$"
    local target_pid=""
    local anchor_pid=""

    hyprctl dispatch plugin:psd:reset "$monitor_name" | grep -qx "ok"

    "$CLIENT_PATH" --title "$target_title" --color "#16f27a" >"$work_dir/$mode-target.log" 2>&1 &
    target_pid=$!
    client_pids+=("$target_pid")

    if [[ "$mode" == "tiled" ]]; then
        "$CLIENT_PATH" --title "$anchor_title" --color "#334a88" >"$work_dir/$mode-anchor.log" 2>&1 &
        anchor_pid=$!
        client_pids+=("$anchor_pid")
    fi

    if ! wait_for_client "$target_title" 0 0; then
        echo "PSD render probe: $mode target did not map tiled." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    if [[ "$mode" == "tiled" ]]; then
        if ! wait_for_client "$anchor_title" 0 0; then
            echo "PSD render probe: tiled anchor did not map." >&2
            hyprctl -j clients >&2 || true
            exit 1
        fi
    else
        hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"
        hyprctl dispatch togglefloating active | grep -qx "ok"

        if ! wait_for_client "$target_title" 1 0; then
            echo "PSD render probe: $mode target did not become floating." >&2
            hyprctl -j clients >&2 || true
            exit 1
        fi

        if [[ "$mode" == "pinned" ]]; then
            hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"
            hyprctl dispatch pin active | grep -qx "ok"

            if ! wait_for_client "$target_title" 1 1; then
                echo "PSD render probe: pinned target did not become pinned." >&2
                hyprctl -j clients >&2 || true
                exit 1
            fi
        fi
    fi

    # Let Qt and the compositor finish their first damage cycle before the
    # baseline screenshot.
    sleep 0.2

    local geometry_before
    geometry_before="$(client_geometry "$target_title")"

    IFS=',' read -r client_x client_y client_w client_h <<<"$geometry_before"

    local monitor_logical_width
    monitor_logical_width="$(
        python3 - "$monitor_width" "$monitor_scale" <<'PY'
import sys
print(float(sys.argv[1]) / float(sys.argv[2]))
PY
    )"

    local client_center_x
    client_center_x="$(
        python3 - "$client_x" "$client_w" <<'PY'
import sys
print(float(sys.argv[1]) + float(sys.argv[2]) / 2.0)
PY
    )"

    local logical_offset=96
    if python3 - "$client_center_x" "$monitor_x" "$monitor_logical_width" <<'PY' >/dev/null
import sys
center = float(sys.argv[1])
monitor_x = float(sys.argv[2])
width = float(sys.argv[3])
raise SystemExit(0 if center < monitor_x + width / 2.0 else 1)
PY
    then
        logical_offset=96
    else
        logical_offset=-96
    fi

    local physical_offset
    physical_offset="$(
        python3 - "$logical_offset" "$monitor_scale" <<'PY'
import sys
print(round(float(sys.argv[1]) * float(sys.argv[2])))
PY
    )"

    local baseline="$work_dir/$mode-baseline.png"
    local shifted="$work_dir/$mode-shifted.png"
    local restored="$work_dir/$mode-restored.png"

    capture_output "$baseline"

    hyprctl dispatch plugin:psd:offset "$monitor_name $logical_offset 0" | grep -qx "ok"
    sleep 0.2

    if [[ "$mode" != "tiled" ]]; then
        local floating_state
        floating_state="$(hyprctl -j psd-plugin-state)"

        python3 - "$floating_state" "$mode" "$logical_offset" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
mode = sys.argv[2]
expected = float(sys.argv[3])
entries = state.get("floatingOffsets", [])

if not entries:
    raise SystemExit(
        f"PSD render probe: {mode} was not tracked as a floating render target; "
        f"state={state}"
    )

entry = entries[0]
print(
    "PSD render probe: "
    f"{mode} floating diagnostic "
    f"applied=({entry.get('appliedX')},{entry.get('appliedY')}) "
    f"current=({entry.get('currentX')},{entry.get('currentY')}) "
    f"pinned={entry.get('pinned')}"
)

if abs(float(entry.get("appliedX", 0.0)) - expected) > 0.01:
    raise SystemExit(
        f"PSD render probe: {mode} tracked wrong applied offset: {entry}"
    )
PY
    fi

    local geometry_shifted
    geometry_shifted="$(client_geometry "$target_title")"
    if [[ "$geometry_shifted" != "$geometry_before" ]]; then
        echo "PSD render probe: $mode logical client geometry changed under render-only offset." >&2
        echo "before=$geometry_before shifted=$geometry_shifted" >&2
        exit 1
    fi

    capture_output "$shifted"
    assert_pixel_translation "$baseline" "$shifted" "$physical_offset" "$mode"

    hyprctl dispatch plugin:psd:reset "$monitor_name" | grep -qx "ok"
    sleep 0.2
    capture_output "$restored"
    assert_pixel_translation "$baseline" "$restored" 0 "$mode reset"

    kill -TERM "$target_pid" >/dev/null 2>&1 || true
    wait "$target_pid" >/dev/null 2>&1 || true
    target_pid=""

    if [[ -n "$anchor_pid" ]]; then
        kill -TERM "$anchor_pid" >/dev/null 2>&1 || true
        wait "$anchor_pid" >/dev/null 2>&1 || true
        anchor_pid=""
    fi

    if ! wait_for_client_gone "$target_title"; then
        echo "PSD render probe: $mode target remained in compositor state after exit." >&2
        exit 1
    fi

    echo "PSD render probe: $mode render-offset semantics PASS"
}

run_case tiled
run_case floating
run_case pinned

echo "PSD render probe: tiled/floating/pinned pixel evidence PASS"
