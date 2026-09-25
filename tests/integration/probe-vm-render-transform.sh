#!/usr/bin/env bash
set -euo pipefail

CLIENT_PATH="${1:-build/tests/psd-integration-client}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"
RENDER_BACKEND="${PSD_RENDER_PROBE_BACKEND:-legacy}"

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

case "$RENDER_BACKEND" in
    legacy|dedicated)
        ;;
    *)
        echo "PSD render probe: unknown backend: $RENDER_BACKEND" >&2
        exit 1
        ;;
esac

apply_transform() {
    local offset="$1"
    if [[ "$RENDER_BACKEND" == "dedicated" ]]; then
        hyprctl dispatch plugin:psd:presentation-offset "$monitor_name $offset 0"
    else
        hyprctl dispatch plugin:psd:offset "$monitor_name $offset 0"
    fi
}

reset_transform() {
    if [[ "$RENDER_BACKEND" == "dedicated" ]]; then
        hyprctl dispatch plugin:psd:presentation-reset "$monitor_name"
    else
        hyprctl dispatch plugin:psd:reset "$monitor_name"
    fi
}

cleanup() {
    set +e

    reset_transform >/dev/null 2>&1 || true
    hyprctl keyword render:direct_scanout 0 >/dev/null 2>&1 || true

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
python3 - "$capabilities" "$RENDER_BACKEND" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["protocolVersion"] == 3, data
assert data["spatialRenderOffsetExperimental"] is True, data
assert data["monitorTargeting"] is True, data
backend = sys.argv[2]
if backend == "dedicated":
    assert data["dedicatedPresentationOffsetExperimental"] is True, data
print(f"PSD render probe: plugin capability handshake PASS backend={backend}")
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


wait_for_client_fullscreen() {
    local title="$1"
    local expected_active="$2"

    for _ in $(seq 1 80); do
        local clients_json
        clients_json="$(hyprctl -j clients)"
        if python3 - "$clients_json" "$title" "$expected_active" <<'PY' >/dev/null 2>&1
import json
import sys

clients = json.loads(sys.argv[1])
title = sys.argv[2]
expected_active = sys.argv[3] == "1"
client = next((item for item in clients if item.get("title") == title), None)
if client is None:
    raise SystemExit(1)

active = int(client.get("fullscreen", 0)) != 0
raise SystemExit(0 if active == expected_active else 1)
PY
        then
            return 0
        fi
        sleep 0.05
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

    # Keep grim deterministic, but do not assume its PNG raster is logical or
    # physical. The probe calibrates that relation from the image dimensions
    # and Hyprland's live output mode/scale.
    grim -s 1 -o "$monitor_name" "$path"
    [[ -s "$path" ]]
}

screenshot_scale_for() {
    local path="$1"

    python3 - "$path" "$monitor_width" "$monitor_height" "$monitor_scale" <<'PY'
from PIL import Image
import sys

image = Image.open(sys.argv[1])
pixel_width = float(sys.argv[2])
pixel_height = float(sys.argv[3])
monitor_scale = float(sys.argv[4])

logical_width = pixel_width / monitor_scale
logical_height = pixel_height / monitor_scale
sx = image.width / logical_width
sy = image.height / logical_height

if abs(sx - sy) > 0.02:
    raise SystemExit(
        "PSD render probe: screenshot coordinate scale is anisotropic "
        f"sx={sx:.6f} sy={sy:.6f} image={image.size} "
        f"mode=({pixel_width},{pixel_height}) monitorScale={monitor_scale}"
    )

print(f"{(sx + sy) / 2.0:.8f}")
PY
}

screenshot_offset_for() {
    local path="$1"
    local logical_offset="$2"
    local screenshot_scale

    screenshot_scale="$(screenshot_scale_for "$path")"
    python3 - "$logical_offset" "$screenshot_scale" <<'PY'
import sys

logical_offset = float(sys.argv[1])
screenshot_scale = float(sys.argv[2])
print(round(logical_offset * screenshot_scale))
PY
}

log_screenshot_calibration() {
    local path="$1"
    local screenshot_scale

    screenshot_scale="$(screenshot_scale_for "$path")"
    python3 - "$path" "$monitor_width" "$monitor_height" "$monitor_scale" "$screenshot_scale" "$RENDER_BACKEND" <<'PY'
from PIL import Image
import sys

image = Image.open(sys.argv[1])
print(
    "PSD render probe: screenshot calibration "
    f"backend={sys.argv[6]} image={image.size[0]}x{image.size[1]} "
    f"mode={sys.argv[2]}x{sys.argv[3]} monitorScale={sys.argv[4]} "
    f"screenshotPxPerLogical={float(sys.argv[5]):.6f}"
)
PY
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

def bbox(points_set):
    xs = [x for x, _ in points_set]
    ys = [y for _, y in points_set]
    return (min(xs), min(ys), max(xs), max(ys))

print(
    f"PSD render probe: {label} mask diagnostic "
    f"baselineBBox={bbox(baseline)} candidateBBox={bbox(candidate)} "
    f"baselinePixels={len(baseline)} candidatePixels={len(candidate)}"
)

best_dx = None
best_overlap = -1

for dx in range(-224, 225, step):
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



state_counter() {
    local field="$1"
    local state

    # Do not combine a pipe with the heredoc that carries the Python source:
    # the heredoc owns stdin. Pass the hyprctl JSON explicitly instead.
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

wait_for_counter_after() {
    local field="$1"
    local before="$2"
    local label="$3"

    for _ in $(seq 1 80); do
        local now
        now="$(state_counter "$field")"
        if (( now > before )); then
            echo "PSD render probe: $label PASS count=$before->$now"
            return
        fi
        sleep 0.05
    done

    echo "PSD render probe: $label did not advance field=$field before=$before" >&2
    hyprctl -j psd-plugin-state >&2 || true
    exit 1
}

wait_for_counter_quiet() {
    local field="$1"
    local label="$2"
    local previous
    local stable_samples=0

    previous="$(state_counter "$field")"

    # Require a full second with no counter growth. This allows any finite
    # compositor follow-up work to settle while rejecting a persistent redraw
    # loop at frequencies >= 1 Hz.
    for _ in $(seq 1 80); do
        sleep 0.05

        local now
        now="$(state_counter "$field")"
        if [[ "$now" == "$previous" ]]; then
            stable_samples=$((stable_samples + 1))
            if (( stable_samples >= 20 )); then
                echo "PSD render probe: $label idle stability PASS count=$now"
                return
            fi
        else
            previous="$now"
            stable_samples=0
        fi
    done

    echo "PSD render probe: $label did not become idle field=$field last=$previous" >&2
    hyprctl -j psd-plugin-state >&2 || true
    exit 1
}

assert_damage_cleanup() {
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

def mask(path):
    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixels = image.load()
    points = set()

    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            if (
                abs(r - target[0]) <= 3
                and abs(g - target[1]) <= 3
                and abs(b - target[2]) <= 3
            ):
                points.add((x, y))

    if len(points) < 10000:
        raise SystemExit(
            f"{label}: too few deterministic client pixels ({len(points)}) in {path}"
        )

    return width, height, points

width, height, baseline = mask(baseline_path)
width2, height2, candidate = mask(candidate_path)
if (width2, height2) != (width, height):
    raise SystemExit(f"{label}: screenshot dimensions changed")

expected = {
    (x + expected_dx, y)
    for x, y in baseline
    if 0 <= x + expected_dx < width
}

missing = expected - candidate
unexpected = candidate - expected
reference = max(1, len(expected))
missing_ratio = len(missing) / reference
unexpected_ratio = len(unexpected) / reference

def bbox(points):
    xs = [x for x, _ in points]
    ys = [y for _, y in points]
    return (min(xs), min(ys), max(xs), max(ys))

print(
    f"PSD render probe: {label} damage diagnostic "
    f"baselineBBox={bbox(baseline)} candidateBBox={bbox(candidate)} "
    f"missing={len(missing)} unexpected={len(unexpected)}"
)

if missing_ratio > 0.01:
    raise SystemExit(
        f"{label}: translated client pixels were not repainted "
        f"(missing ratio={missing_ratio:.4f})"
    )

if unexpected_ratio > 0.01:
    raise SystemExit(
        f"{label}: stale/ghost client pixels remained after damage "
        f"(unexpected ratio={unexpected_ratio:.4f})"
    )

print(
    f"PSD render probe: {label} old/new damage cleanup "
    f"{expected_dx}px PASS"
)
PY
}

assert_decoration_translation() {
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
target = (255, 0, 255)

def points(path):
    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixels = image.load()
    result = set()

    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            if (
                abs(r - target[0]) <= 6
                and abs(g - target[1]) <= 6
                and abs(b - target[2]) <= 6
            ):
                result.add((x, y))

    if len(result) < 500:
        raise SystemExit(
            f"{label}: too few compositor-border pixels ({len(result)}) in {path}"
        )
    return result

baseline = points(baseline_path)
candidate = points(candidate_path)

def bbox(points_set):
    xs = [x for x, _ in points_set]
    ys = [y for _, y in points_set]
    return (min(xs), min(ys), max(xs), max(ys))

best_dx = None
best_overlap = -1

for dx in range(-224, 225):
    overlap = sum((x + dx, y) in candidate for x, y in baseline)
    if overlap > best_overlap:
        best_overlap = overlap
        best_dx = dx

overlap_ratio = best_overlap / max(1, min(len(baseline), len(candidate)))

print(
    f"PSD render probe: {label} decoration diagnostic "
    f"baselineBBox={bbox(baseline)} candidateBBox={bbox(candidate)} "
    f"baselinePixels={len(baseline)} candidatePixels={len(candidate)}"
)

if abs(best_dx - expected_dx) > 3:
    raise SystemExit(
        f"{label}: expected compositor-border translation {expected_dx}, "
        f"best correlation was {best_dx} (overlap={overlap_ratio:.3f})"
    )

if overlap_ratio < 0.65:
    raise SystemExit(
        f"{label}: weak compositor-border correlation "
        f"{overlap_ratio:.3f} at dx={best_dx}"
    )

print(
    f"PSD render probe: {label} decoration pixel translation "
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

    reset_transform | grep -qx "ok"

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

        # togglefloating preserves the former tiled geometry. On a one-window
        # workspace that can be essentially monitor-sized, making translation
        # correlation ambiguous: a uniform full-screen rectangle shifted and
        # clipped still correlates perfectly at dx=0. Force a compact,
        # centered floating geometry so the pixel test has visible margins on
        # both sides and can distinguish 0 from +/-96 unambiguously.
        hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"
        hyprctl dispatch resizeactive "exact 480 320" | grep -qx "ok"
        hyprctl dispatch centerwindow | grep -qx "ok"

        floating_geometry_ready=0
        for _ in $(seq 1 60); do
            geometry_now="$(client_geometry "$target_title" || true)"
            if python3 - "$geometry_now" "$monitor_x" "$monitor_y" "$monitor_width" "$monitor_height" "$monitor_scale" <<'PY' >/dev/null 2>&1
import sys

if not sys.argv[1]:
    raise SystemExit(1)

x, y, w, h = map(int, sys.argv[1].split(","))
monitor_x = int(sys.argv[2])
monitor_y = int(sys.argv[3])
monitor_width = int(sys.argv[4])
monitor_height = int(sys.argv[5])
scale = float(sys.argv[6])

logical_width = monitor_width / scale
logical_height = monitor_height / scale

if abs(w - 480) > 4 or abs(h - 320) > 4:
    raise SystemExit(1)

left_margin = x - monitor_x
right_margin = monitor_x + logical_width - (x + w)
top_margin = y - monitor_y
bottom_margin = monitor_y + logical_height - (y + h)

# Leave substantially more than the 96-unit test translation on every side.
if min(left_margin, right_margin) < 160:
    raise SystemExit(1)
if min(top_margin, bottom_margin) < 80:
    raise SystemExit(1)
PY
            then
                floating_geometry_ready=1
                break
            fi
            sleep 0.1
        done

        if [[ "$floating_geometry_ready" != "1" ]]; then
            echo "PSD render probe: $mode target did not settle to compact centered floating geometry." >&2
            hyprctl -j clients >&2 || true
            exit 1
        fi

        echo "PSD render probe: $mode compact floating geometry $geometry_now PASS"

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

    local screenshot_offset=""

    local baseline="$work_dir/$mode-baseline.png"
    local shifted="$work_dir/$mode-shifted.png"
    local restored="$work_dir/$mode-restored.png"

    capture_output "$baseline"
    screenshot_offset="$(screenshot_offset_for "$baseline" "$logical_offset")"
    log_screenshot_calibration "$baseline"

    apply_transform "$logical_offset" | grep -qx "ok"
    sleep 0.2

    local compositor_state
    local client_state
    compositor_state="$(hyprctl -j psd-plugin-state)"
    client_state="$(hyprctl -j clients)"

    python3 - "$compositor_state" "$client_state" "$mode" "$target_title" "$logical_offset" "$RENDER_BACKEND" "$monitor_name" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
clients = json.loads(sys.argv[2])
mode = sys.argv[3]
title = sys.argv[4]
expected = float(sys.argv[5])
backend = sys.argv[6]
monitor = sys.argv[7]

client = next((item for item in clients if item.get("title") == title), None)
if client is None:
    raise SystemExit(f"PSD render probe: {mode} client disappeared")

if backend == "dedicated":
    entries = [
        item for item in state.get("dedicatedPresentationOffsets", [])
        if item.get("monitor") == monitor
    ]
    if len(entries) != 1:
        raise SystemExit(
            f"PSD render probe: {mode} unexpected dedicated transform state: {state}"
        )
    entry = entries[0]
    if abs(float(entry.get("x", 0.0)) - expected) > 0.01:
        raise SystemExit(
            f"PSD render probe: {mode} wrong dedicated x offset: {entry}"
        )
    if abs(float(entry.get("y", 0.0))) > 0.01:
        raise SystemExit(
            f"PSD render probe: {mode} wrong dedicated y offset: {entry}"
        )
    print(
        "PSD render probe: "
        f"{mode} dedicated presentation diagnostic "
        f"offset=({entry.get('x')},{entry.get('y')})"
    )
else:
    transforms = state.get("trackedTransforms", [])
    if len(transforms) != 1:
        raise SystemExit(f"PSD render probe: {mode} unexpected transform state: {state}")

    transform = transforms[0]
    workspace = client.get("workspace", {})
    print(
        "PSD render probe: "
        f"{mode} workspace diagnostic "
        f"clientWorkspace={workspace.get('name')} "
        f"trackedWorkspace={transform.get('workspace')} "
        f"requested=({transform.get('requestedX')},{transform.get('requestedY')}) "
        f"actual=({transform.get('actualX')},{transform.get('actualY')}) "
        f"goal=({transform.get('goalX')},{transform.get('goalY')}) "
        f"animated={transform.get('animated')}"
    )

    if str(workspace.get("name", "")) != str(transform.get("workspace", "")):
        raise SystemExit(
            f"PSD render probe: {mode} client/tracked workspace mismatch: "
            f"client={workspace} transform={transform}"
        )
PY

    if [[ "$RENDER_BACKEND" == "legacy" && "$mode" != "tiled" ]]; then
        python3 - "$compositor_state" "$mode" "$logical_offset" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
mode = sys.argv[2]
expected = float(sys.argv[3])
entries = state.get("presentationOffsets", [])
want_pinned = mode == "pinned"
entries = [entry for entry in entries if bool(entry.get("pinned")) == want_pinned]

if not entries:
    raise SystemExit(
        f"PSD render probe: {mode} was not tracked as a presentation target; "
        f"state={state}"
    )

entry = entries[0]
print(
    "PSD render probe: "
    f"{mode} presentation diagnostic "
    f"strategy={entry.get('strategy')} "
    f"observedBefore=({entry.get('observedBeforeX')},{entry.get('observedBeforeY')}) "
    f"applied=({entry.get('appliedX')},{entry.get('appliedY')}) "
    f"current=({entry.get('currentX')},{entry.get('currentY')}) "
    f"pinned={entry.get('pinned')}"
)

expected_presentation = expected if want_pinned else 0.0
if abs(float(entry.get("appliedX", 0.0)) - expected_presentation) > 0.01:
    raise SystemExit(
        f"PSD render probe: {mode} tracked wrong presentation offset: {entry}"
    )
if abs(float(entry.get("currentX", 0.0)) - expected_presentation) > 0.01:
    raise SystemExit(
        f"PSD render probe: {mode} compositor presentation offset diverged: {entry}"
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
    assert_pixel_translation "$baseline" "$shifted" "$screenshot_offset" "$mode"

    reset_transform | grep -qx "ok"
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

    echo "PSD render probe: $mode render-offset semantics PASS backend=$RENDER_BACKEND"
}


run_popup_case() {
    if [[ "$RENDER_BACKEND" != "dedicated" ]]; then
        return
    fi

    local mode="xdg-popup"
    local target_title="psd-render-$mode-$$"
    local target_pid=""
    local client_log="$work_dir/$mode-client.log"
    local baseline="$work_dir/$mode-baseline.png"
    local shifted="$work_dir/$mode-shifted.png"
    local restored="$work_dir/$mode-restored.png"
    local logical_offset=96
    local screenshot_offset=""

    reset_transform | grep -qx "ok"

    WAYLAND_DEBUG=1 "$CLIENT_PATH" \
        --title "$target_title" \
        --color "#334a88" \
        --popup \
        --popup-color "#16f27a" \
        >"$client_log" 2>&1 &
    target_pid=$!
    client_pids+=("$target_pid")

    if ! wait_for_client "$target_title" 0 0; then
        echo "PSD render probe: popup parent did not map tiled." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"
    hyprctl dispatch togglefloating active | grep -qx "ok"
    hyprctl dispatch resizeactive "exact 640 480" | grep -qx "ok"
    hyprctl dispatch centerwindow | grep -qx "ok"

    if ! wait_for_client "$target_title" 1 0; then
        echo "PSD render probe: popup parent did not become floating." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local geometry_ready=0
    local geometry_now=""
    for _ in $(seq 1 60); do
        geometry_now="$(client_geometry "$target_title" || true)"
        if python3 - "$geometry_now" <<'PY' >/dev/null 2>&1
import sys
if not sys.argv[1]:
    raise SystemExit(1)
_, _, w, h = map(int, sys.argv[1].split(","))
raise SystemExit(0 if abs(w - 640) <= 4 and abs(h - 480) <= 4 else 1)
PY
        then
            geometry_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ "$geometry_ready" != "1" ]]; then
        echo "PSD render probe: popup parent geometry did not settle." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local popup_protocol_ready=0
    for _ in $(seq 1 80); do
        if grep -q "get_popup" "$client_log"; then
            popup_protocol_ready=1
            break
        fi
        if ! kill -0 "$target_pid" >/dev/null 2>&1; then
            echo "PSD render probe: popup client exited before creating xdg_popup." >&2
            cat "$client_log" >&2 || true
            exit 1
        fi
        sleep 0.1
    done

    if [[ "$popup_protocol_ready" != "1" ]]; then
        echo "PSD render probe: Qt popup did not emit an xdg_popup request." >&2
        cat "$client_log" >&2 || true
        exit 1
    fi
    echo "PSD render probe: xdg_popup protocol evidence PASS"

    local popup_pixels_ready=0
    for _ in $(seq 1 60); do
        capture_output "$baseline"
    screenshot_offset="$(screenshot_offset_for "$baseline" "$logical_offset")"
    log_screenshot_calibration "$baseline"
        if python3 - "$baseline" <<'PY' >/dev/null 2>&1
from PIL import Image
import sys
target = (22, 242, 122)
image = Image.open(sys.argv[1]).convert("RGB")
count = sum(
    1
    for pixel in image.getdata()
    if all(abs(pixel[i] - target[i]) <= 3 for i in range(3))
)
raise SystemExit(0 if count >= 4000 else 1)
PY
        then
            popup_pixels_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ "$popup_pixels_ready" != "1" ]]; then
        echo "PSD render probe: xdg_popup did not become visible with deterministic pixels." >&2
        cat "$client_log" >&2 || true
        exit 1
    fi

    local geometry_before
    geometry_before="$(client_geometry "$target_title")"

    apply_transform "$logical_offset" | grep -qx "ok"
    sleep 0.2

    local compositor_state
    compositor_state="$(hyprctl -j psd-plugin-state)"
    python3 - "$compositor_state" "$monitor_name" "$logical_offset" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
expected = float(sys.argv[3])
entries = [
    item for item in state.get("dedicatedPresentationOffsets", [])
    if item.get("monitor") == monitor
]
if len(entries) != 1:
    raise SystemExit(
        f"PSD render probe: popup unexpected dedicated transform state: {state}"
    )
entry = entries[0]
if abs(float(entry.get("x", 0.0)) - expected) > 0.01:
    raise SystemExit(
        f"PSD render probe: popup wrong dedicated x offset: {entry}"
    )
if abs(float(entry.get("y", 0.0))) > 0.01:
    raise SystemExit(
        f"PSD render probe: popup wrong dedicated y offset: {entry}"
    )
PY

    local geometry_shifted
    geometry_shifted="$(client_geometry "$target_title")"
    if [[ "$geometry_shifted" != "$geometry_before" ]]; then
        echo "PSD render probe: popup parent logical geometry changed under render-only offset." >&2
        echo "before=$geometry_before shifted=$geometry_shifted" >&2
        exit 1
    fi

    capture_output "$shifted"
    assert_pixel_translation "$baseline" "$shifted" "$screenshot_offset" "$mode"

    reset_transform | grep -qx "ok"
    sleep 0.2
    capture_output "$restored"
    assert_pixel_translation "$baseline" "$restored" 0 "$mode reset"

    kill -TERM "$target_pid" >/dev/null 2>&1 || true
    wait "$target_pid" >/dev/null 2>&1 || true
    target_pid=""

    if ! wait_for_client_gone "$target_title"; then
        echo "PSD render probe: popup parent remained in compositor state after exit." >&2
        exit 1
    fi

    echo "PSD render probe: xdg_popup pixel evidence PASS backend=$RENDER_BACKEND"
}


run_subsurface_case() {
    if [[ "$RENDER_BACKEND" != "dedicated" ]]; then
        return
    fi

    local mode="wl-subsurface"
    local target_title="psd-render-$mode-$$"
    local target_pid=""
    local client_log="$work_dir/$mode-client.log"
    local baseline="$work_dir/$mode-baseline.png"
    local shifted="$work_dir/$mode-shifted.png"
    local restored="$work_dir/$mode-restored.png"
    local logical_offset=96
    local screenshot_offset=""

    reset_transform | grep -qx "ok"

    WAYLAND_DEBUG=1 "$CLIENT_PATH" \
        --title "$target_title" \
        --color "#334a88" \
        --subsurface \
        --subsurface-color "#16f27a" \
        >"$client_log" 2>&1 &
    target_pid=$!
    client_pids+=("$target_pid")

    if ! wait_for_client "$target_title" 0 0; then
        echo "PSD render probe: subsurface parent did not map tiled." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"
    hyprctl dispatch togglefloating active | grep -qx "ok"
    hyprctl dispatch resizeactive "exact 640 480" | grep -qx "ok"
    hyprctl dispatch centerwindow | grep -qx "ok"

    if ! wait_for_client "$target_title" 1 0; then
        echo "PSD render probe: subsurface parent did not become floating." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local geometry_ready=0
    local geometry_now=""
    for _ in $(seq 1 60); do
        geometry_now="$(client_geometry "$target_title" || true)"
        if python3 - "$geometry_now" <<'PY' >/dev/null 2>&1
import sys
if not sys.argv[1]:
    raise SystemExit(1)
_, _, w, h = map(int, sys.argv[1].split(","))
raise SystemExit(0 if abs(w - 640) <= 4 and abs(h - 480) <= 4 else 1)
PY
        then
            geometry_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ "$geometry_ready" != "1" ]]; then
        echo "PSD render probe: subsurface parent geometry did not settle." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local subsurface_protocol_ready=0
    for _ in $(seq 1 80); do
        if grep -q "get_subsurface" "$client_log"; then
            subsurface_protocol_ready=1
            break
        fi
        if ! kill -0 "$target_pid" >/dev/null 2>&1; then
            echo "PSD render probe: subsurface client exited before wl_subsurface creation." >&2
            cat "$client_log" >&2 || true
            exit 1
        fi
        sleep 0.1
    done

    if [[ "$subsurface_protocol_ready" != "1" ]]; then
        echo "PSD render probe: Qt native child did not emit wl_subcompositor.get_subsurface." >&2
        cat "$client_log" >&2 || true
        exit 1
    fi
    echo "PSD render probe: wl_subsurface protocol evidence PASS"

    local child_pixels_ready=0
    for _ in $(seq 1 60); do
        capture_output "$baseline"
    screenshot_offset="$(screenshot_offset_for "$baseline" "$logical_offset")"
    log_screenshot_calibration "$baseline"
        if python3 - "$baseline" <<'PY' >/dev/null 2>&1
from PIL import Image
import sys
target = (22, 242, 122)
image = Image.open(sys.argv[1]).convert("RGB")
count = sum(
    1
    for pixel in image.getdata()
    if all(abs(pixel[i] - target[i]) <= 3 for i in range(3))
)
raise SystemExit(0 if count >= 4000 else 1)
PY
        then
            child_pixels_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ "$child_pixels_ready" != "1" ]]; then
        echo "PSD render probe: wl_subsurface did not become visible with deterministic pixels." >&2
        cat "$client_log" >&2 || true
        exit 1
    fi

    local geometry_before
    geometry_before="$(client_geometry "$target_title")"

    apply_transform "$logical_offset" | grep -qx "ok"
    sleep 0.2

    local compositor_state
    compositor_state="$(hyprctl -j psd-plugin-state)"
    python3 - "$compositor_state" "$monitor_name" "$logical_offset" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
expected = float(sys.argv[3])
entries = [
    item for item in state.get("dedicatedPresentationOffsets", [])
    if item.get("monitor") == monitor
]
if len(entries) != 1:
    raise SystemExit(
        f"PSD render probe: subsurface unexpected dedicated transform state: {state}"
    )
entry = entries[0]
if abs(float(entry.get("x", 0.0)) - expected) > 0.01:
    raise SystemExit(
        f"PSD render probe: subsurface wrong dedicated x offset: {entry}"
    )
if abs(float(entry.get("y", 0.0))) > 0.01:
    raise SystemExit(
        f"PSD render probe: subsurface wrong dedicated y offset: {entry}"
    )
PY

    local geometry_shifted
    geometry_shifted="$(client_geometry "$target_title")"
    if [[ "$geometry_shifted" != "$geometry_before" ]]; then
        echo "PSD render probe: subsurface parent logical geometry changed under render-only offset." >&2
        echo "before=$geometry_before shifted=$geometry_shifted" >&2
        exit 1
    fi

    capture_output "$shifted"
    assert_pixel_translation "$baseline" "$shifted" "$screenshot_offset" "$mode"

    reset_transform | grep -qx "ok"
    sleep 0.2
    capture_output "$restored"
    assert_pixel_translation "$baseline" "$restored" 0 "$mode reset"

    kill -TERM "$target_pid" >/dev/null 2>&1 || true
    wait "$target_pid" >/dev/null 2>&1 || true
    target_pid=""

    if ! wait_for_client_gone "$target_title"; then
        echo "PSD render probe: subsurface parent remained in compositor state after exit." >&2
        exit 1
    fi

    echo "PSD render probe: wl_subsurface pixel evidence PASS backend=$RENDER_BACKEND"
}


run_decoration_case() {
    if [[ "$RENDER_BACKEND" != "dedicated" ]]; then
        return
    fi

    local mode="compositor-decoration"
    local target_title="psd-render-$mode-$$"
    local target_pid=""
    local baseline="$work_dir/$mode-baseline.png"
    local shifted="$work_dir/$mode-shifted.png"
    local restored="$work_dir/$mode-restored.png"

    reset_transform | grep -qx "ok"

    "$CLIENT_PATH" \
        --title "$target_title" \
        --color "#334a88" \
        >"$work_dir/$mode-client.log" 2>&1 &
    target_pid=$!
    client_pids+=("$target_pid")

    if ! wait_for_client "$target_title" 0 0; then
        echo "PSD render probe: decoration target did not map tiled." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"
    hyprctl dispatch togglefloating active | grep -qx "ok"
    hyprctl dispatch resizeactive "exact 480 320" | grep -qx "ok"
    hyprctl dispatch centerwindow | grep -qx "ok"

    if ! wait_for_client "$target_title" 1 0; then
        echo "PSD render probe: decoration target did not become floating." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local geometry_ready=0
    local geometry_now=""
    for _ in $(seq 1 60); do
        geometry_now="$(client_geometry "$target_title" || true)"
        if python3 - "$geometry_now" <<'PY' >/dev/null 2>&1
import sys
if not sys.argv[1]:
    raise SystemExit(1)
_, _, w, h = map(int, sys.argv[1].split(","))
raise SystemExit(0 if abs(w - 480) <= 4 and abs(h - 320) <= 4 else 1)
PY
        then
            geometry_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ "$geometry_ready" != "1" ]]; then
        echo "PSD render probe: decoration target geometry did not settle." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    # The top-level paints only blue. Magenta therefore comes exclusively
    # from the deterministic Hyprland border configured by the headless test
    # session, giving us compositor-owned decoration pixels to correlate.
    sleep 0.2

    local geometry_before
    geometry_before="$(client_geometry "$target_title")"

    local logical_offset=96
    local screenshot_offset=""

    capture_output "$baseline"
    screenshot_offset="$(screenshot_offset_for "$baseline" "$logical_offset")"
    log_screenshot_calibration "$baseline"
    assert_decoration_translation "$baseline" "$baseline" 0 "$mode baseline"

    apply_transform "$logical_offset" | grep -qx "ok"
    sleep 0.2

    local compositor_state
    compositor_state="$(hyprctl -j psd-plugin-state)"
    python3 - "$compositor_state" "$monitor_name" "$logical_offset" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
expected = float(sys.argv[3])
entries = [
    item for item in state.get("dedicatedPresentationOffsets", [])
    if item.get("monitor") == monitor
]
if len(entries) != 1:
    raise SystemExit(
        f"PSD render probe: decoration unexpected dedicated transform state: {state}"
    )
entry = entries[0]
if abs(float(entry.get("x", 0.0)) - expected) > 0.01:
    raise SystemExit(
        f"PSD render probe: decoration wrong dedicated x offset: {entry}"
    )
if abs(float(entry.get("y", 0.0))) > 0.01:
    raise SystemExit(
        f"PSD render probe: decoration wrong dedicated y offset: {entry}"
    )
PY

    local geometry_shifted
    geometry_shifted="$(client_geometry "$target_title")"
    if [[ "$geometry_shifted" != "$geometry_before" ]]; then
        echo "PSD render probe: decoration target logical geometry changed under render-only offset." >&2
        echo "before=$geometry_before shifted=$geometry_shifted" >&2
        exit 1
    fi

    capture_output "$shifted"
    assert_decoration_translation "$baseline" "$shifted" "$screenshot_offset" "$mode"

    reset_transform | grep -qx "ok"
    sleep 0.2
    capture_output "$restored"
    assert_decoration_translation "$baseline" "$restored" 0 "$mode reset"

    kill -TERM "$target_pid" >/dev/null 2>&1 || true
    wait "$target_pid" >/dev/null 2>&1 || true
    target_pid=""

    if ! wait_for_client_gone "$target_title"; then
        echo "PSD render probe: decoration target remained in compositor state after exit." >&2
        exit 1
    fi

    echo "PSD render probe: compositor decoration pixel evidence PASS backend=$RENDER_BACKEND"
}


run_damage_case() {
    if [[ "$RENDER_BACKEND" != "dedicated" ]]; then
        return
    fi

    local mode="damage"
    local target_title="psd-render-${mode}-${BASHPID}"
    local target_pid=""
    local baseline="$work_dir/$mode-baseline.png"
    local shifted="$work_dir/$mode-shifted.png"
    local restored="$work_dir/$mode-restored.png"

    reset_transform | grep -qx "ok"

    "$CLIENT_PATH" \
        --title "$target_title" \
        --color "#16f27a" \
        >"$work_dir/$mode-client.log" 2>&1 &
    target_pid=$!
    client_pids+=("$target_pid")

    if ! wait_for_client "$target_title" 0 0; then
        echo "PSD render probe: damage target did not map tiled." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"
    hyprctl dispatch togglefloating active | grep -qx "ok"
    hyprctl dispatch resizeactive "exact 480 320" | grep -qx "ok"
    hyprctl dispatch centerwindow | grep -qx "ok"

    if ! wait_for_client "$target_title" 1 0; then
        echo "PSD render probe: damage target did not become floating." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local geometry_ready=0
    local geometry_now=""
    for _ in $(seq 1 60); do
        geometry_now="$(client_geometry "$target_title" || true)"
        if python3 - "$geometry_now" <<'PY' >/dev/null 2>&1
import sys
if not sys.argv[1]:
    raise SystemExit(1)
_, _, w, h = map(int, sys.argv[1].split(","))
raise SystemExit(0 if abs(w - 480) <= 4 and abs(h - 320) <= 4 else 1)
PY
        then
            geometry_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ "$geometry_ready" != "1" ]]; then
        echo "PSD render probe: damage target geometry did not settle." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    sleep 0.2

    local geometry_before
    geometry_before="$(client_geometry "$target_title")"

    local logical_offset=96
    local screenshot_offset=""

    capture_output "$baseline"
    screenshot_offset="$(screenshot_offset_for "$baseline" "$logical_offset")"
    log_screenshot_calibration "$baseline"
    wait_for_counter_quiet "monitorRenderCounts" "$mode baseline render"

    local damage_before
    local render_before
    damage_before="$(state_counter "dedicatedDamageRequests")"
    render_before="$(state_counter "monitorRenderCounts")"

    apply_transform "$logical_offset" | grep -qx "ok"

    wait_for_counter_after \
        "dedicatedDamageRequests" "$damage_before" "$mode apply damage request"
    wait_for_counter_after \
        "monitorRenderCounts" "$render_before" "$mode apply compositor frame"
    wait_for_counter_quiet \
        "dedicatedDamageRequests" "$mode apply damage requests"
    wait_for_counter_quiet \
        "monitorRenderCounts" "$mode apply render"

    local geometry_shifted
    geometry_shifted="$(client_geometry "$target_title")"
    if [[ "$geometry_shifted" != "$geometry_before" ]]; then
        echo "PSD render probe: damage target logical geometry changed under render-only offset." >&2
        echo "before=$geometry_before shifted=$geometry_shifted" >&2
        exit 1
    fi

    capture_output "$shifted"
    assert_damage_cleanup "$baseline" "$shifted" "$screenshot_offset" "$mode apply"

    wait_for_counter_quiet "monitorRenderCounts" "$mode shifted screenshot settle"

    local damage_before_reset
    local render_before_reset
    damage_before_reset="$(state_counter "dedicatedDamageRequests")"
    render_before_reset="$(state_counter "monitorRenderCounts")"

    reset_transform | grep -qx "ok"

    wait_for_counter_after \
        "dedicatedDamageRequests" "$damage_before_reset" "$mode reset damage request"
    wait_for_counter_after \
        "monitorRenderCounts" "$render_before_reset" "$mode reset compositor frame"
    wait_for_counter_quiet \
        "dedicatedDamageRequests" "$mode reset damage requests"
    wait_for_counter_quiet \
        "monitorRenderCounts" "$mode reset render"

    capture_output "$restored"
    assert_damage_cleanup "$shifted" "$restored" "$((-screenshot_offset))" "$mode reset"

    kill -TERM "$target_pid" >/dev/null 2>&1 || true
    wait "$target_pid" >/dev/null 2>&1 || true
    target_pid=""

    if ! wait_for_client_gone "$target_title"; then
        echo "PSD render probe: damage target remained in compositor state after exit." >&2
        exit 1
    fi

    echo "PSD render probe: dedicated damage/event-driven evidence PASS"
}


run_direct_scanout_guard_case() {
    if [[ "$RENDER_BACKEND" != "dedicated" ]]; then
        return
    fi

    local mode="direct-scanout-guard"
    local target_title="psd-render-${mode}-${BASHPID}"
    local target_pid=""
    local logical_offset=96

    echo "PSD render probe: direct-scanout guard begin title=$target_title"
    reset_transform | grep -qx "ok"
    hyprctl keyword render:direct_scanout 1 | grep -qx "ok"

    "$CLIENT_PATH" \
        --title "$target_title" \
        --color "#334a88" \
        >"$work_dir/$mode-client.log" 2>&1 &
    target_pid=$!
    client_pids+=("$target_pid")

    if ! wait_for_client "$target_title" 0 0; then
        echo "PSD render probe: direct-scanout guard target did not map." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    hyprctl dispatch focuswindow "title:^$target_title$" | grep -qx "ok"

    # Maximized is still CENTER in PSD. It must remain spatially movable.
    hyprctl dispatch fullscreen "1 set" | grep -qx "ok"
    if ! wait_for_client_fullscreen "$target_title" 1; then
        echo "PSD render probe: maximize state did not become active." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    apply_transform "$logical_offset" | grep -qx "ok"

    local maximized_state
    maximized_state="$(hyprctl -j psd-plugin-state)"
    python3 - "$maximized_state" "$monitor_name" "$logical_offset" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
expected = float(sys.argv[3])
entries = [
    item for item in state.get("dedicatedPresentationOffsets", [])
    if item.get("monitor") == monitor
]
if len(entries) != 1:
    raise SystemExit(
        f"PSD render probe: maximized CENTER lost dedicated offset: {state}"
    )
entry = entries[0]
if abs(float(entry.get("x", 0.0)) - expected) > 0.01:
    raise SystemExit(
        f"PSD render probe: maximized CENTER wrong offset: {entry}"
    )
PY
    echo "PSD render probe: maximized CENTER remains spatially movable PASS"

    hyprctl dispatch fullscreen "1 unset" | grep -qx "ok"
    if ! wait_for_client_fullscreen "$target_title" 0; then
        echo "PSD render probe: maximize state did not clear." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local recenter_before
    local damage_before
    local render_before
    recenter_before="$(state_counter "fullscreenDedicatedResetCounts")"
    damage_before="$(state_counter "dedicatedDamageRequests")"
    render_before="$(state_counter "monitorRenderCounts")"

    # Explicit fullscreen owns the whole monitor. The compositor callback must
    # recenter PSD before a direct-scanout candidate can bypass renderWindow().
    hyprctl dispatch fullscreen "0 set" | grep -qx "ok"
    if ! wait_for_client_fullscreen "$target_title" 1; then
        echo "PSD render probe: explicit fullscreen did not become active." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    wait_for_counter_after \
        "fullscreenDedicatedResetCounts" "$recenter_before" "$mode fullscreen recenter"
    wait_for_counter_after \
        "dedicatedDamageRequests" "$damage_before" "$mode fullscreen recenter damage"
    wait_for_counter_after \
        "monitorRenderCounts" "$render_before" "$mode fullscreen recenter frame"

    local fullscreen_state
    fullscreen_state="$(hyprctl -j psd-plugin-state)"
    python3 - "$fullscreen_state" "$monitor_name" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
entries = [
    item for item in state.get("dedicatedPresentationOffsets", [])
    if item.get("monitor") == monitor
]
if entries:
    raise SystemExit(
        f"PSD render probe: explicit fullscreen coexists with PSD offset: {state}"
    )
PY

    local fullscreen_client_state
    fullscreen_client_state="$(hyprctl -j clients)"
    python3 - "$fullscreen_client_state" "$target_title" "$monitor_x" "$monitor_y" "$monitor_width" "$monitor_height" "$monitor_scale" <<'PY'
import json
import sys

clients = json.loads(sys.argv[1])
title = sys.argv[2]
monitor_x = int(sys.argv[3])
monitor_y = int(sys.argv[4])
pixel_width = int(sys.argv[5])
pixel_height = int(sys.argv[6])
scale = float(sys.argv[7])
client = next((item for item in clients if item.get("title") == title), None)
if client is None:
    raise SystemExit("PSD render probe: fullscreen client disappeared")

at = client.get("at", [0, 0])
size = client.get("size", [0, 0])
logical_width = round(pixel_width / scale)
logical_height = round(pixel_height / scale)

if abs(int(at[0]) - monitor_x) > 2 or abs(int(at[1]) - monitor_y) > 2:
    raise SystemExit(
        f"PSD render probe: explicit fullscreen position is not monitor origin: {client}"
    )
if abs(int(size[0]) - logical_width) > 4 or abs(int(size[1]) - logical_height) > 4:
    raise SystemExit(
        f"PSD render probe: explicit fullscreen does not occupy whole monitor: {client}"
    )
PY
    echo "PSD render probe: explicit fullscreen owns full monitor with zero PSD offset PASS"

    local refused_output
    local refused_status
    set +e
    refused_output="$(apply_transform "$logical_offset" 2>&1)"
    refused_status=$?
    set -e

    if [[ "$refused_output" == "ok" ]] || [[ "$refused_output" != *"refusing dedicated presentation offset while explicit fullscreen content is active"* ]]; then
        echo "PSD render probe: explicit fullscreen accepted a new PSD offset unexpectedly." >&2
        echo "status=$refused_status output=$refused_output" >&2
        exit 1
    fi
    echo "PSD render probe: explicit fullscreen rejects new PSD offset PASS"

    # The QEMU/Qt client may not provide a scanout-capable DMA-BUF. Record the
    # compositor's actual DS state without claiming hardware zero-copy success.
    local monitor_state
    monitor_state="$(hyprctl -j monitors)"
    python3 - "$monitor_state" "$monitor_name" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
name = sys.argv[2]
monitor = next((item for item in monitors if item.get("name") == name), None)
if monitor is None:
    raise SystemExit("PSD render probe: monitor disappeared during DS characterization")

print(
    "PSD render probe: direct-scanout diagnostic "
    f"target={monitor.get('directScanoutTo')} "
    f"blockedBy={monitor.get('directScanoutBlockedBy')}"
)
PY

    hyprctl dispatch fullscreen "0 unset" | grep -qx "ok"
    if ! wait_for_client_fullscreen "$target_title" 0; then
        echo "PSD render probe: explicit fullscreen did not clear." >&2
        hyprctl -j clients >&2 || true
        exit 1
    fi

    local after_exit_state
    after_exit_state="$(hyprctl -j psd-plugin-state)"
    python3 - "$after_exit_state" "$monitor_name" <<'PY'
import json
import sys

state = json.loads(sys.argv[1])
monitor = sys.argv[2]
entries = [
    item for item in state.get("dedicatedPresentationOffsets", [])
    if item.get("monitor") == monitor
]
if entries:
    raise SystemExit(
        f"PSD render probe: fullscreen exit restored stale PSD offset: {state}"
    )
PY

    hyprctl keyword render:direct_scanout 0 | grep -qx "ok"

    kill -TERM "$target_pid" >/dev/null 2>&1 || true
    wait "$target_pid" >/dev/null 2>&1 || true
    target_pid=""

    if ! wait_for_client_gone "$target_title"; then
        echo "PSD render probe: direct-scanout guard target remained after exit." >&2
        exit 1
    fi

    echo "PSD render probe: fullscreen/direct-scanout guard semantics PASS"
}

run_case tiled
run_case floating
run_case pinned
run_popup_case
run_subsurface_case
run_decoration_case
run_damage_case
run_direct_scanout_guard_case

echo "PSD render probe: tiled/floating/pinned pixel evidence PASS backend=$RENDER_BACKEND"
