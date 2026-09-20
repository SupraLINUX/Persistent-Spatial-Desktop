#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe="$repo_root/tests/integration/probe-live-session.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
mock_log="$tmp_dir/hyprctl.log"
plugin_state="$tmp_dir/plugin-loaded"
transform_state="$tmp_dir/transform-state.json"
shell_ready="$tmp_dir/shell-ready"
fake_plugin="$tmp_dir/psd-hyprland-plugin.so"
fake_shell="$tmp_dir/psd-shell"

touch "$fake_plugin"

cat >"$tmp_dir/bin/hyprctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

log="${PSD_MOCK_LOG:?}"
plugin_state="${PSD_MOCK_PLUGIN_STATE:?}"
transform_state="${PSD_MOCK_TRANSFORM_STATE:?}"
shell_ready="${PSD_MOCK_SHELL_READY:?}"

printf '%s\n' "$*" >>"$log"

case "$*" in
    "-j layers")
        if [[ -e "$shell_ready" ]]; then
            printf '%s\n' '{"DP-1":{"levels":{"0":[{"namespace":"psd-shell:DP-1"}],"2":[{"namespace":"psd-gutter:DP-1:left"},{"namespace":"psd-gutter:DP-1:right"},{"namespace":"psd-gutter:DP-1:top"},{"namespace":"psd-gutter:DP-1:dash"}]}}}'
        else
            printf '%s\n' '{"DP-1":{"levels":{"0":[]}}}'
        fi
        ;;
    "-j plugin list")
        if [[ -e "$plugin_state" ]]; then
            printf '%s\n' '[{"name":"psd-hyprland-plugin"}]'
        else
            printf '%s\n' '[]'
        fi
        ;;
    "plugin load "*)
        touch "$plugin_state"
        printf '%s\n' 'ok'
        ;;
    "plugin unload "*)
        rm -f "$plugin_state"
        printf '%s\n' 'ok'
        ;;
    "-j psd-plugin")
        [[ -e "$plugin_state" ]] || exit 1
        printf '%s\n' '{"protocolVersion":3,"pluginVersion":"0.1.1","spatialRenderOffsetExperimental":true,"monitorTargeting":true,"fourFingerGestureEventsExperimental":true,"gestureEventsDefaultEnabled":false,"diagnosticStateQueryExperimental":true,"lifecycleEventsExperimental":true}'
        ;;
    "-j psd-plugin-state")
        [[ -e "$plugin_state" ]] || exit 1
        if [[ -e "$transform_state" ]]; then
            cat "$transform_state"
        else
            printf '%s\n' '{"trackedTransforms":[],"touchedWorkspaceCount":0,"workspaceSwitchResetCount":0,"gestureEventsEnabled":false,"gestureActive":false}'
        fi
        ;;
    "-j monitors")
        printf '%s\n' '[{"id":0,"name":"DP-1","focused":true}]'
        ;;
    "dispatch plugin:psd:gesture-events "*)
        [[ -e "$plugin_state" ]] || exit 1
        printf '%s\n' 'ok'
        ;;
    "dispatch plugin:psd:offset "*)
        [[ -e "$plugin_state" ]] || exit 1
        set -- $*
        monitor="${3}"
        x="${4}"
        y="${5}"
        printf '{"trackedTransforms":[{"monitor":"%s","workspaceGeneration":1,"x":%s,"y":%s}],"touchedWorkspaceCount":1,"workspaceSwitchResetCount":0,"gestureEventsEnabled":false,"gestureActive":false}\n' \
            "$monitor" "$x" "$y" >"$transform_state"
        printf '%s\n' 'ok'
        ;;
    "dispatch plugin:psd:reset "*)
        [[ -e "$plugin_state" ]] || exit 1
        rm -f "$transform_state"
        printf '%s\n' 'ok'
        ;;
    *)
        echo "mock hyprctl: unexpected command: $*" >&2
        exit 2
        ;;
esac
SH
chmod +x "$tmp_dir/bin/hyprctl"

cat >"$fake_shell" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ready="${PSD_MOCK_SHELL_READY:?}"

cleanup() {
    rm -f "$ready"
}

terminate() {
    cleanup
    exit 0
}

trap cleanup EXIT
trap terminate TERM INT

touch "$ready"
while :; do
    sleep 1
done
SH
chmod +x "$fake_shell"

run_probe() {
    env \
        PATH="$tmp_dir/bin:$PATH" \
        HYPRLAND_INSTANCE_SIGNATURE=mock \
        PSD_MOCK_LOG="$mock_log" \
        PSD_MOCK_PLUGIN_STATE="$plugin_state" \
        PSD_MOCK_TRANSFORM_STATE="$transform_state" \
        PSD_MOCK_SHELL_READY="$shell_ready" \
        "$@"
}

# Scenario 1: the session already owns the plugin. The probe must leave it
# loaded, but it still has to reset every monitor before returning.
: >"$mock_log"
rm -f "$transform_state"
touch "$plugin_state"
output="$(
    run_probe PSD_PROBE_EXERCISE_OFFSET=1 \
        bash "$probe" "$fake_shell" "$fake_plugin"
)"

grep -q 'PSD live probe: PASS' <<<"$output"
grep -q 'dispatch plugin:psd:gesture-events 1' "$mock_log"
grep -q 'dispatch plugin:psd:gesture-events 0' "$mock_log"
grep -q 'dispatch plugin:psd:offset DP-1 24 0' "$mock_log"
grep -q 'dispatch plugin:psd:reset DP-1' "$mock_log"
[[ -e "$plugin_state" ]]
[[ ! -e "$shell_ready" ]]

# Scenario 2: the probe owns plugin load/unload and must leave no plugin state.
: >"$mock_log"
rm -f "$transform_state"
rm -f "$plugin_state"
output="$(
    run_probe bash "$probe" "$fake_shell" "$fake_plugin"
)"

grep -q 'PSD live probe: PASS' <<<"$output"
grep -q "^plugin load $fake_plugin$" "$mock_log"
grep -q "^plugin unload $fake_plugin$" "$mock_log"
[[ ! -e "$plugin_state" ]]
[[ ! -e "$shell_ready" ]]

# Scenario 3: missing build artifacts must produce the probe's diagnostic,
# not an early realpath failure caused by set -e.
set +e
missing_output="$(
    run_probe bash "$probe" "$tmp_dir/does-not-exist" "$fake_plugin" 2>&1
)"
missing_status=$?
set -e

[[ "$missing_status" -ne 0 ]]
grep -q 'PSD live probe: shell binary not found:' <<<"$missing_output"

echo "PSD live probe mock harness: PASS"
