#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe="$repo_root/tests/integration/probe-hardware-nvidia.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p \
    "$tmp_dir/bin" \
    "$tmp_dir/sys/module/nvidia_drm/parameters" \
    "$tmp_dir/sys/class/drm/card0-DP-1/device" \
    "$tmp_dir/sys/drivers/nvidia"

printf '%s\n' Y >"$tmp_dir/sys/module/nvidia_drm/parameters/modeset"
ln -s "$tmp_dir/sys/drivers/nvidia" "$tmp_dir/sys/class/drm/card0-DP-1/device/driver"

mock_log="$tmp_dir/hyprctl.log"
plugin_state="$tmp_dir/plugin-loaded"
offset_state="$tmp_dir/dedicated-offset"
direct_state="$tmp_dir/direct-scanout"
fullscreen_state="$tmp_dir/fullscreen"
client_title_state="$tmp_dir/client-title"
fake_plugin="$tmp_dir/psd-hyprland-plugin.so"
fake_client="$tmp_dir/psd-integration-client"

touch "$fake_plugin"
printf '%s\n' 0 >"$direct_state"

cat >"$tmp_dir/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'NVIDIA GeForce RTX 3090, 595.45.04, 00000000:01:00.0'
SH
chmod +x "$tmp_dir/bin/nvidia-smi"

# El probe usa sleep sólo para polling. En el mock no necesitamos esperar.
cat >"$tmp_dir/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp_dir/bin/sleep"

cat >"$tmp_dir/bin/hyprctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

log="${PSD_HW_MOCK_LOG:?}"
plugin_state="${PSD_HW_MOCK_PLUGIN_STATE:?}"
offset_state="${PSD_HW_MOCK_OFFSET_STATE:?}"
direct_state="${PSD_HW_MOCK_DIRECT_STATE:?}"
fullscreen_state="${PSD_HW_MOCK_FULLSCREEN_STATE:?}"
client_title_state="${PSD_HW_MOCK_CLIENT_TITLE_STATE:?}"
scanout_mode="${PSD_HW_MOCK_SCANOUT_MODE:?}"
mock_vrr="${PSD_HW_MOCK_VRR:?}"

printf '%s\n' "$*" >>"$log"

case "$*" in
    "version")
        printf '%s\n' 'Hyprland 0.53.3 built from branch v0.53.3 at commit dd220efe'
        ;;
    "systeminfo")
        printf '%s\n' 'Backend: drm'
        ;;
    "-j getoption render:direct_scanout")
        value="$(cat "$direct_state")"
        printf '{"int":%s}\n' "$value"
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
        printf '%s\n' ok
        ;;
    "plugin unload "*)
        rm -f "$plugin_state"
        printf '%s\n' ok
        ;;
    "-j psd-plugin")
        printf '%s\n' '{"protocolVersion":3,"pluginVersion":"0.1.10","dedicatedPresentationOffsetExperimental":true,"diagnosticStateQueryExperimental":true}'
        ;;
    "-j psd-plugin-state")
        if [[ -e "$offset_state" ]]; then
            read -r monitor x y <"$offset_state"
            printf '{"dedicatedPresentationOffsets":[{"monitor":"%s","x":%s,"y":%s}]}\n' "$monitor" "$x" "$y"
        else
            printf '%s\n' '{"dedicatedPresentationOffsets":[]}'
        fi
        ;;
    "-j clients")
        if [[ -e "$fullscreen_state" && -e "$client_title_state" ]]; then
            title="$(cat "$client_title_state")"
            printf '[{"title":"%s","fullscreen":2,"monitor":0}]\n' "$title"
        else
            printf '%s\n' '[]'
        fi
        ;;
    "-j monitors")
        direct_to="0"
        blocked='["USER","CANDIDATE"]'
        vrr=false
        if [[ -e "$fullscreen_state" && "$(cat "$direct_state")" == "1" ]]; then
            if [[ "$scanout_mode" == "active" ]]; then
                direct_to="0x1234"
                blocked='[]'
                vrr="$mock_vrr"
            else
                blocked='["CANDIDATE","SURFACE"]'
            fi
        fi
        printf '[{"id":0,"name":"DP-1","focused":true,"vrr":%s,"mirrorOf":"none","currentFormat":"XRGB8888","scale":1.0,"transform":0,"directScanoutTo":"%s","directScanoutBlockedBy":%s}]\n' \
            "$vrr" "$direct_to" "$blocked"
        ;;
    "dispatch focusmonitor "*)
        printf '%s\n' ok
        ;;
    "keyword render:direct_scanout "*)
        set -- $*
        printf '%s\n' "$3" >"$direct_state"
        printf '%s\n' ok
        ;;
    "dispatch plugin:psd:presentation-reset "*)
        rm -f "$offset_state"
        printf '%s\n' ok
        ;;
    "dispatch plugin:psd:presentation-offset "*)
        set -- $*
        if [[ -e "$fullscreen_state" ]]; then
            echo 'PSD: refusing dedicated presentation offset while explicit fullscreen content is active' >&2
            exit 1
        fi
        printf '%s %s %s\n' "$3" "$4" "$5" >"$offset_state"
        printf '%s\n' ok
        ;;
    *)
        echo "mock hyprctl: unexpected command: $*" >&2
        exit 2
        ;;
esac
SH
chmod +x "$tmp_dir/bin/hyprctl"

cat >"$fake_client" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

fullscreen_state="${PSD_HW_MOCK_FULLSCREEN_STATE:?}"
client_title_state="${PSD_HW_MOCK_CLIENT_TITLE_STATE:?}"
title=""

while (( $# > 0 )); do
    case "$1" in
        --title)
            title="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

cleanup() {
    rm -f "$fullscreen_state" "$client_title_state"
}

terminate() {
    cleanup
    exit 0
}

trap cleanup EXIT
trap terminate TERM INT

printf '%s\n' "$title" >"$client_title_state"
touch "$fullscreen_state"

while :; do
    /bin/sleep 3600 &
    wait $! || true
done
SH
chmod +x "$fake_client"

reset_state() {
    : >"$mock_log"
    rm -f "$plugin_state" "$offset_state" "$fullscreen_state" "$client_title_state"
    printf '%s\n' 0 >"$direct_state"
}

run_probe() {
    local scanout_mode="$1"
    local vrr="$2"
    local require_vrr="$3"

    env \
        PATH="$tmp_dir/bin:$PATH" \
        HYPRLAND_INSTANCE_SIGNATURE=mock \
        PSD_HW_CONFIRM=I_UNDERSTAND_DISPLAY_MAY_FLICKER \
        PSD_HW_TEST_MODE=1 \
        PSD_HW_TEST_SYSFS_ROOT="$tmp_dir/sys" \
        PSD_HW_MONITOR=DP-1 \
        PSD_HW_REQUIRE_VRR="$require_vrr" \
        PSD_HW_MOCK_LOG="$mock_log" \
        PSD_HW_MOCK_PLUGIN_STATE="$plugin_state" \
        PSD_HW_MOCK_OFFSET_STATE="$offset_state" \
        PSD_HW_MOCK_DIRECT_STATE="$direct_state" \
        PSD_HW_MOCK_FULLSCREEN_STATE="$fullscreen_state" \
        PSD_HW_MOCK_CLIENT_TITLE_STATE="$client_title_state" \
        PSD_HW_MOCK_SCANOUT_MODE="$scanout_mode" \
        PSD_HW_MOCK_VRR="$vrr" \
        bash "$probe" "$fake_plugin" "$fake_client"
}

assert_clean() {
    [[ "$(cat "$direct_state")" == "0" ]]
    [[ ! -e "$plugin_state" ]]
    [[ ! -e "$offset_state" ]]
    [[ ! -e "$fullscreen_state" ]]
    [[ ! -e "$client_title_state" ]]
}

# 1. Camino nominal: direct scanout + VRR.
reset_state
output="$(run_probe active true 1)"
grep -q 'real direct scanout ACTIVE' <<<"$output"
grep -q 'active VRR during real direct scanout PASS' <<<"$output"
grep -q 'MOCK control-flow characterization PASS' <<<"$output"
! grep -q 'NVIDIA hardware characterization PASS' <<<"$output"
grep -q '^keyword render:direct_scanout 1$' "$mock_log"
grep -q '^keyword render:direct_scanout 0$' "$mock_log"
assert_clean

# 2. Direct scanout nunca se vuelve elegible: diagnóstico y exit 2.
reset_state
set +e
output="$(run_probe blocked false 1 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]]
grep -q 'REAL DIRECT SCANOUT NOT ACHIEVED' <<<"$output"
grep -q 'CANDIDATE' <<<"$output"
grep -q 'SURFACE' <<<"$output"
assert_clean

# 3. Scanout activo pero VRR requerido ausente: exit 3.
reset_state
set +e
output="$(run_probe active false 1 2>&1)"
status=$?
set -e
[[ "$status" -eq 3 ]]
grep -q 'active VRR was required and is false' <<<"$output"
assert_clean

# 4. Scanout-only: VRR puede estar ausente, pero no se certifica VRR.
reset_state
output="$(run_probe active false 0)"
grep -q 'active VRR NOT validated (PSD_HW_REQUIRE_VRR=0)' <<<"$output"
grep -q 'MOCK control-flow characterization PASS' <<<"$output"
! grep -q 'NVIDIA hardware characterization PASS' <<<"$output"
assert_clean

echo "PSD NVIDIA hardware probe mock harness: PASS"
