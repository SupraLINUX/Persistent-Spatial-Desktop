#!/usr/bin/env bash
set -euo pipefail

CLIENT_PATH="${1:-build/tests/psd-integration-client}"
PLUGIN_PATH="${2:-build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so}"

for command in hyprctl python3 realpath; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "PSD workspace-animation probe: missing command: $command" >&2
        exit 1
    fi
done

for path in "$CLIENT_PATH" "$PLUGIN_PATH"; do
    if [[ ! -e "$path" ]]; then
        echo "PSD workspace-animation probe: required path not found: $path" >&2
        exit 1
    fi
done

CLIENT_PATH="$(realpath "$CLIENT_PATH")"
PLUGIN_PATH="$(realpath "$PLUGIN_PATH")"

if [[ ! -x "$CLIENT_PATH" || ! -f "$PLUGIN_PATH" ]]; then
    echo "PSD workspace-animation probe: invalid client/plugin artifact" >&2
    exit 1
fi

monitor_json="$(hyprctl -j monitors)"
read -r monitor_name original_workspace < <(
    python3 - "$monitor_json" <<'PY'
import json
import sys

monitors = json.loads(sys.argv[1])
if not monitors:
    raise SystemExit("no active monitor")

monitor = next((item for item in monitors if item.get("focused")), monitors[0])
workspace = str(monitor.get("activeWorkspace", {}).get("name", "")).strip()
if not workspace:
    raise SystemExit("focused monitor has no active workspace")

print(monitor["name"], workspace)
PY
)

original_workspace_selector="$original_workspace"
if [[ ! "$original_workspace" =~ ^[0-9]+$ ]]; then
    original_workspace_selector="name:$original_workspace"
fi

workspace_a=$((9000 + ($$ % 400)))
workspace_b=$((workspace_a + 1))
title_a="psd-native-animation-a-$$"
title_b="psd-native-animation-b-$$"
owns_plugin=0
client_pids=()

cleanup() {
    set +e

    hyprctl keyword animations:enabled false >/dev/null 2>&1 || true
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
}
trap cleanup EXIT

wait_for_client() {
    local title="$1"
    local workspace="$2"

    for _ in $(seq 1 60); do
        if hyprctl -j clients | python3 -c '
import json,sys
title=sys.argv[1]
workspace=sys.argv[2]
clients=json.load(sys.stdin)
ok=any(
    c.get("title")==title
    and str(c.get("workspace",{}).get("name",""))==workspace
    for c in clients
)
raise SystemExit(0 if ok else 1)
' "$title" "$workspace"; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

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
assert data["nativeWorkspaceAnimationDiagnosticsExperimental"] is True, data
print("PSD workspace-animation probe: diagnostic capability PASS")
PY

# Prepare two persistent workspaces with animations disabled so setup itself
# cannot contaminate the measurement.
hyprctl keyword animations:enabled false | grep -qx "ok"
hyprctl dispatch focusmonitor "$monitor_name" | grep -qx "ok"
hyprctl dispatch workspace "$workspace_a" | grep -qx "ok"

"$CLIENT_PATH" --title "$title_a" --color "#CC3355" >/tmp/psd-native-animation-a.log 2>&1 &
client_a_pid=$!
client_pids+=("$client_a_pid")
wait_for_client "$title_a" "$workspace_a"

hyprctl dispatch workspace "$workspace_b" | grep -qx "ok"
"$CLIENT_PATH" --title "$title_b" --color "#33AA66" >/tmp/psd-native-animation-b.log 2>&1 &
client_b_pid=$!
client_pids+=("$client_b_pid")
wait_for_client "$title_b" "$workspace_b"

hyprctl dispatch workspace "$workspace_a" | grep -qx "ok"
hyprctl dispatch plugin:psd:reset "$monitor_name" | grep -qx "ok"

# Use an intentionally slow linear slide so the in-flight native
# m_renderOffset is observable after the synchronous workspace dispatch.
hyprctl keyword animation "workspaces,1,1,default,slide" | grep -qx "ok"
hyprctl keyword animation "workspacesIn,1,1,default,slide" | grep -qx "ok"
hyprctl keyword animation "workspacesOut,1,1,default,slide" | grep -qx "ok"
hyprctl keyword animations:enabled true | grep -qx "ok"

# Control: native workspace switching alone must animate the incoming active
# workspace and settle back at zero.
hyprctl dispatch workspace "$workspace_b" | grep -qx "ok"

native_seen=0
for _ in $(seq 1 40); do
    state="$(hyprctl -j psd-plugin-state)"
    if python3 - "$state" "$monitor_name" "$workspace_b" <<'PY' >/dev/null 2>&1
import json
import sys

state=json.loads(sys.argv[1])
monitor=sys.argv[2]
workspace=sys.argv[3]
items=[
    x for x in state.get("activeWorkspaceAnimations", [])
    if x.get("monitor")==monitor and str(x.get("workspace",""))==workspace
]
if len(items)!=1 or items[0].get("animated") is not True:
    raise SystemExit(1)
item=items[0]
if abs(float(item.get("actualX",0))) < 1.0 and abs(float(item.get("actualY",0))) < 1.0:
    raise SystemExit(1)
PY
    then
        native_seen=1
        break
    fi
    sleep 0.025
done

if [[ "$native_seen" != "1" ]]; then
    echo "PSD workspace-animation probe: could not observe native workspace animation." >&2
    hyprctl -j psd-plugin-state >&2 || true
    exit 1
fi

echo "PSD workspace-animation probe: native m_renderOffset animation observable PASS"

native_settled=0
for _ in $(seq 1 120); do
    state="$(hyprctl -j psd-plugin-state)"
    if python3 - "$state" "$monitor_name" "$workspace_b" <<'PY' >/dev/null 2>&1
import json
import sys

state=json.loads(sys.argv[1])
monitor=sys.argv[2]
workspace=sys.argv[3]
items=[
    x for x in state.get("activeWorkspaceAnimations", [])
    if x.get("monitor")==monitor and str(x.get("workspace",""))==workspace
]
if len(items)!=1:
    raise SystemExit(1)
item=items[0]
if item.get("animated") is True:
    raise SystemExit(1)
if abs(float(item.get("actualX",0))) > 0.5 or abs(float(item.get("actualY",0))) > 0.5:
    raise SystemExit(1)
PY
    then
        native_settled=1
        break
    fi
    sleep 0.05
done

if [[ "$native_settled" != "1" ]]; then
    echo "PSD workspace-animation probe: native workspace animation did not settle cleanly." >&2
    hyprctl -j psd-plugin-state >&2 || true
    exit 1
fi

echo "PSD workspace-animation probe: native animation settles to zero PASS"

# Return without animation, establish a PSD transform, then switch to B with
# native animation enabled and issue the same PSD transform immediately.
hyprctl keyword animations:enabled false | grep -qx "ok"
hyprctl dispatch workspace "$workspace_a" | grep -qx "ok"
hyprctl dispatch plugin:psd:reset "$monitor_name" | grep -qx "ok"

before_state="$(hyprctl -j psd-plugin-state)"
before_conflicts="$(python3 - "$before_state" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("nativeWorkspaceAnimationConflictCount", 0))
PY
)"

hyprctl dispatch plugin:psd:offset "$monitor_name 96 0" | grep -qx "ok"
hyprctl keyword animations:enabled true | grep -qx "ok"
hyprctl dispatch workspace "$workspace_b" | grep -qx "ok"
hyprctl dispatch plugin:psd:offset "$monitor_name 96 0" | grep -qx "ok"

collision_state="$(hyprctl -j psd-plugin-state)"
python3 - "$collision_state" "$monitor_name" "$workspace_b" "$before_conflicts" <<'PY'
import json
import sys

state=json.loads(sys.argv[1])
monitor=sys.argv[2]
workspace=sys.argv[3]
before=int(sys.argv[4])
after=int(state.get("nativeWorkspaceAnimationConflictCount",0))
conflict=state.get("lastNativeWorkspaceAnimationConflict")

if after <= before:
    raise SystemExit(
        "PSD workspace-animation probe: expected shared m_renderOffset collision was not observed"
    )
if not isinstance(conflict, dict):
    raise SystemExit(f"missing conflict snapshot: {state}")
if conflict.get("monitor") != monitor or str(conflict.get("workspace","")) != workspace:
    raise SystemExit(f"collision targeted unexpected workspace: {conflict}")

native_before=(
    float(conflict.get("actualBeforeX",0)),
    float(conflict.get("actualBeforeY",0)),
)
native_goal=(
    float(conflict.get("goalBeforeX",0)),
    float(conflict.get("goalBeforeY",0)),
)
requested=(
    float(conflict.get("requestedX",0)),
    float(conflict.get("requestedY",0)),
)

if abs(native_before[0]) < 1.0 and abs(native_before[1]) < 1.0:
    raise SystemExit(f"collision snapshot did not capture an in-flight native offset: {conflict}")
if abs(requested[0] - 96.0) > 0.01 or abs(requested[1]) > 0.01:
    raise SystemExit(f"unexpected PSD request in conflict snapshot: {conflict}")

active=[
    x for x in state.get("activeWorkspaceAnimations", [])
    if x.get("monitor")==monitor and str(x.get("workspace",""))==workspace
]
print(
    "PSD workspace-animation probe: shared m_renderOffset collision CONFIRMED "
    f"nativeBefore={native_before} nativeGoal={native_goal} requested={requested} "
    f"postCommand={active[0] if active else None}"
)
PY

hyprctl dispatch plugin:psd:reset "$monitor_name" | grep -qx "ok"
hyprctl keyword animations:enabled false | grep -qx "ok"

echo "PSD workspace-animation probe: characterization PASS (collision confirmed)"
