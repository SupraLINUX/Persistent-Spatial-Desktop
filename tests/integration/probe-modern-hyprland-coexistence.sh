#!/usr/bin/env bash
set -euo pipefail

prefix="${1:-/opt/psd-hyprland}"
config_path="${2:-tests/integration/hyprland-headless.conf}"

if [[ ! -x "$prefix/bin/Hyprland" || ! -x "$prefix/bin/hyprctl" ]]; then
    echo "PSD modern probe: private Hyprland runtime is incomplete under $prefix" >&2
    exit 1
fi

if [[ ! -f "$config_path" ]]; then
    echo "PSD modern probe: config not found: $config_path" >&2
    exit 1
fi

prefix="$(realpath "$prefix")"
config_path="$(realpath "$config_path")"

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && "${PSD_MODERN_DBUS_WRAPPED:-0}" != "1" ]]; then
    if ! command -v dbus-run-session >/dev/null 2>&1; then
        echo "PSD modern probe: dbus-run-session is required for application smoke tests" >&2
        exit 1
    fi
    exec dbus-run-session -- env PSD_MODERN_DBUS_WRAPPED=1 "$0" "$prefix" "$config_path"
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$(mktemp -d)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

hypr_log="${TMPDIR:-/tmp}/psd-modern-hyprland.log"
app_log_dir="${TMPDIR:-/tmp}/psd-modern-apps"
mkdir -p "$app_log_dir"

private_exec() {
    env \
        PATH="$prefix/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        LD_LIBRARY_PATH="$prefix/lib" \
        "$@"
}

hyprctl_private() {
    private_exec "$prefix/bin/hyprctl" "$@"
}

private_exec "$prefix/bin/Hyprland" --i-am-really-stupid --config "$config_path" >"$hypr_log" 2>&1 &
hypr_pid=$!

cleanup() {
    set +e
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        hyprctl_private dispatch exit >/dev/null 2>&1 || true
    fi
    kill "$hypr_pid" >/dev/null 2>&1 || true
    wait "$hypr_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

instance_dir=""
for _ in $(seq 1 150); do
    instance_dir="$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)"
    if [[ -n "$instance_dir" && -S "$instance_dir/.socket.sock" ]]; then
        break
    fi
    if ! kill -0 "$hypr_pid" >/dev/null 2>&1; then
        echo "PSD modern probe: Hyprland exited before IPC became ready" >&2
        cat "$hypr_log" >&2 || true
        exit 1
    fi
    sleep 0.1
done

if [[ -z "$instance_dir" || ! -S "$instance_dir/.socket.sock" ]]; then
    echo "PSD modern probe: Hyprland IPC did not become ready" >&2
    cat "$hypr_log" >&2 || true
    exit 1
fi

export HYPRLAND_INSTANCE_SIGNATURE="$(basename "$instance_dir")"

monitor_name="$(hyprctl_private -j monitors | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["name"] if d else "")')"
if [[ -z "$monitor_name" ]]; then
    hyprctl_private output create headless PSD-MODERN-CI >/dev/null
    for _ in $(seq 1 50); do
        monitor_name="$(hyprctl_private -j monitors | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["name"] if d else "")')"
        [[ -n "$monitor_name" ]] && break
        sleep 0.1
    done
fi

if [[ -z "$monitor_name" ]]; then
    echo "PSD modern probe: no output became available" >&2
    cat "$hypr_log" >&2 || true
    exit 1
fi

wayland_display="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' 2>/dev/null | head -n1 || true)"
if [[ -z "$wayland_display" ]]; then
    echo "PSD modern probe: compositor Wayland socket not found" >&2
    find "$XDG_RUNTIME_DIR" -maxdepth 2 -ls >&2 || true
    exit 1
fi

private_exec "$prefix/bin/Hyprland" --version
hyprctl_private -j monitors >/dev/null
hyprctl_private -j workspaces >/dev/null
echo "PSD modern probe: compositor IPC/runtime PASS on $monitor_name ($wayland_display)"

smoke_window() {
    local label="$1"
    local regex="$2"
    shift 2
    local log="$app_log_dir/$label.log"

    env -u LD_LIBRARY_PATH \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        WAYLAND_DISPLAY="$wayland_display" \
        XDG_SESSION_TYPE=wayland \
        XDG_CURRENT_DESKTOP=Hyprland \
        GDK_BACKEND=wayland \
        QT_QPA_PLATFORM=wayland \
        "$@" >"$log" 2>&1 &
    local pid=$!

    local matched=0
    for _ in $(seq 1 120); do
        if hyprctl_private -j clients | python3 - "$regex" <<'PY'
import json
import re
import sys

pattern = re.compile(sys.argv[1], re.I)
clients = json.load(sys.stdin)
for client in clients:
    haystack = " ".join(str(client.get(k, "")) for k in ("class", "initialClass", "title", "initialTitle"))
    if pattern.search(haystack):
        raise SystemExit(0)
raise SystemExit(1)
PY
        then
            matched=1
            break
        fi
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            # D-Bus activated applications may hand off to another process; keep checking clients.
            :
        fi
        sleep 0.1
    done

    if [[ "$matched" != "1" ]]; then
        echo "PSD modern probe: $label did not create a Wayland window" >&2
        cat "$log" >&2 || true
        hyprctl_private -j clients >&2 || true
        return 1
    fi

    echo "PSD modern probe: $label Wayland window PASS"
}

smoke_window dolphin 'dolphin' dolphin --new-window /tmp
smoke_window nautilus 'nautilus|org\.gnome\.Nautilus' nautilus --new-window /tmp

if env -u LD_LIBRARY_PATH ldd /usr/bin/dolphin 2>/dev/null | grep -q "$prefix"; then
    echo "PSD modern probe: Dolphin resolved private compositor libraries" >&2
    exit 1
fi
if env -u LD_LIBRARY_PATH ldd /usr/bin/nautilus 2>/dev/null | grep -q "$prefix"; then
    echo "PSD modern probe: Nautilus resolved private compositor libraries" >&2
    exit 1
fi

echo "PSD modern probe: Ubuntu application isolation PASS"
