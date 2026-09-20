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

runtime_dir="$(mktemp -d)"
log_file="${TMPDIR:-/tmp}/psd-hyprland-vm-runtime.log"
hyprland_pid=""

cleanup() {
    set +e

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        hyprctl dispatch exit >/dev/null 2>&1 || true
    fi

    if [[ -n "$hyprland_pid" ]]; then
        kill "$hyprland_pid" >/dev/null 2>&1 || true
        wait "$hyprland_pid" >/dev/null 2>&1 || true
    fi

    rm -rf "$runtime_dir"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$runtime_dir"
chmod 700 "$XDG_RUNTIME_DIR"
export HYPRLAND_HEADLESS_ONLY=1

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

echo "PSD VM runtime probe: using guest DRM render node(s):"
ls -l /dev/dri/renderD*
echo "PSD VM runtime probe: using Hyprland output $monitor_name"

PSD_PROBE_EXERCISE_RUNTIME=1     bash "$(dirname "$0")/probe-live-session.sh" "$SHELL_PATH" "$PLUGIN_PATH"

echo "PSD VM runtime probe: PASS"
