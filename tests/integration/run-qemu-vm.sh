#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/psd-qemu-vm"
image_cache="${PSD_VM_IMAGE_CACHE:-${HOME}/.cache/psd-vm/ubuntu-26.04-minimal-cloudimg-amd64.img}"
image_url="${PSD_VM_IMAGE_URL:-https://cloud-images.ubuntu.com/minimal/releases/resolute/release-20260827/ubuntu-26.04-minimal-cloudimg-amd64.img}"
ssh_port="${PSD_VM_SSH_PORT:-2222}"

for command in qemu-system-x86_64 qemu-img cloud-localds curl ssh ssh-keygen tar; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "PSD QEMU probe: missing host command: $command" >&2
        exit 1
    fi
done

rm -rf "$work_dir"
mkdir -p "$work_dir" "$(dirname "$image_cache")"

serial_log="$work_dir/qemu-serial.log"
qemu_log="$work_dir/qemu.log"
pid_file="$work_dir/qemu.pid"
disk_image="$work_dir/ubuntu-26.04.qcow2"
seed_image="$work_dir/seed.img"
ssh_key="$work_dir/id_ed25519"
user_data="$work_dir/user-data"
qemu_pid=""

cleanup() {
    local status=$?
    set +e

    if [[ -f "$pid_file" ]]; then
        qemu_pid="$(cat "$pid_file" 2>/dev/null || true)"
    fi

    if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" >/dev/null 2>&1; then
        kill "$qemu_pid" >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            kill -0 "$qemu_pid" >/dev/null 2>&1 || break
            sleep 0.1
        done
        kill -KILL "$qemu_pid" >/dev/null 2>&1 || true
    fi

    if [[ "$status" -ne 0 ]]; then
        echo "===== PSD QEMU host log =====" >&2
        cat "$qemu_log" >&2 2>/dev/null || true
        echo "===== PSD QEMU guest serial =====" >&2
        tail -n 400 "$serial_log" >&2 2>/dev/null || true
    fi

    exit "$status"
}
trap cleanup EXIT

if [[ ! -s "$image_cache" ]]; then
    echo "PSD QEMU probe: downloading Ubuntu Minimal 26.04 image"
    curl --fail --location --retry 4 --retry-delay 2         "$image_url"         --output "$image_cache.part"
    mv "$image_cache.part" "$image_cache"
fi

cp --reflink=auto "$image_cache" "$disk_image" 2>/dev/null     || cp "$image_cache" "$disk_image"
qemu-img resize "$disk_image" 12G >/dev/null

ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"

cat >"$user_data" <<EOF
#cloud-config
users:
  - name: psd
    gecos: PSD CI
    groups: [adm, sudo, video, render]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$ssh_key.pub")
ssh_pwauth: false
disable_root: true
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
EOF

cloud-localds "$seed_image" "$user_data"

ovmf_code=""
ovmf_vars=""
for candidate in     /usr/share/OVMF/OVMF_CODE_4M.fd     /usr/share/OVMF/OVMF_CODE.fd; do
    if [[ -f "$candidate" ]]; then
        ovmf_code="$candidate"
        break
    fi
done

for candidate in     /usr/share/OVMF/OVMF_VARS_4M.fd     /usr/share/OVMF/OVMF_VARS.fd; do
    if [[ -f "$candidate" ]]; then
        ovmf_vars="$candidate"
        break
    fi
done

if [[ -z "$ovmf_code" || -z "$ovmf_vars" ]]; then
    echo "PSD QEMU probe: OVMF firmware not found" >&2
    exit 1
fi

vars_image="$work_dir/OVMF_VARS.fd"
cp "$ovmf_vars" "$vars_image"

accel="tcg"
cpu="max"
if [[ -c /dev/kvm ]]; then
    sudo chmod a+rw /dev/kvm >/dev/null 2>&1 || true
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        accel="kvm"
        cpu="host"
    fi
fi

echo "PSD QEMU probe: selected accelerator $accel"

base_args=(
    -name psd-ubuntu-26.04
    -machine "q35,accel=$accel"
    -cpu "$cpu"
    -smp 3
    -m 6144
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
    -drive "if=pflash,format=raw,file=$vars_image"
    -drive "file=$disk_image,if=virtio,format=qcow2,cache=unsafe"
    -drive "file=$seed_image,if=virtio,format=raw,readonly=on"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22"
    -device virtio-net-pci,netdev=net0
    -serial "file:$serial_log"
    -monitor none
    -no-reboot
    -pidfile "$pid_file"
    -daemonize
)

start_vm() {
    local gpu_mode="$1"
    rm -f "$pid_file"
    : >"$qemu_log"

    if [[ "$gpu_mode" == "virgl" ]]; then
        echo "PSD QEMU probe: trying virtio-vga-gl with software host GL"
        if LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe             qemu-system-x86_64 "${base_args[@]}"             -device virtio-vga-gl             -display egl-headless,gl=on             >"$qemu_log" 2>&1; then
            sleep 2
            [[ -f "$pid_file" ]] || return 1
            qemu_pid="$(cat "$pid_file")"
            kill -0 "$qemu_pid" >/dev/null 2>&1
            return
        fi
        return 1
    fi

    echo "PSD QEMU probe: falling back to 2D virtio-vga"
    qemu-system-x86_64 "${base_args[@]}"         -device virtio-vga         -display none         >"$qemu_log" 2>&1

    sleep 2
    [[ -f "$pid_file" ]] || return 1
    qemu_pid="$(cat "$pid_file")"
    kill -0 "$qemu_pid" >/dev/null 2>&1
}

if qemu-system-x86_64 -device help 2>&1 | grep -q 'virtio-vga-gl'     && qemu-system-x86_64 -display help 2>&1 | grep -q 'egl-headless'; then
    if ! start_vm virgl; then
        cp "$ovmf_vars" "$vars_image"
        start_vm virtio
    fi
else
    start_vm virtio
fi

ssh_options=(
    -i "$ssh_key"
    -p "$ssh_port"
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=2
    -o ServerAliveInterval=10
)

ssh_guest() {
    ssh "${ssh_options[@]}" psd@127.0.0.1 "$@"
}

echo "PSD QEMU probe: waiting for guest SSH"
ssh_ready=0
for _ in $(seq 1 240); do
    if ssh_guest true >/dev/null 2>&1; then
        ssh_ready=1
        break
    fi

    if [[ -n "$qemu_pid" ]] && ! kill -0 "$qemu_pid" >/dev/null 2>&1; then
        echo "PSD QEMU probe: QEMU exited before SSH became ready" >&2
        exit 1
    fi

    sleep 1
done

if [[ "$ssh_ready" != "1" ]]; then
    echo "PSD QEMU probe: guest SSH did not become ready" >&2
    exit 1
fi

ssh_guest 'sudo cloud-init status --wait || true'

echo "PSD QEMU probe: installing Ubuntu 26.04 guest dependencies"
ssh_guest '
    set -e
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends         ca-certificates         build-essential         cmake         git         ninja-build         pkgconf         python3         qt6-base-dev         qt6-declarative-dev         qt6-wayland         liblayershellqtinterface-dev         hyprland         hyprland-dev         libgles-dev         seatd \
        xdg-desktop-portal-hyprland
'

echo "PSD QEMU probe: guest kernel/DRM state"
ssh_guest '
    uname -a
    echo "--- /dev/dri ---"
    ls -la /dev/dri || true
    echo "--- DRM drivers ---"
    for driver in /sys/class/drm/card*/device/driver; do
        [[ -e "$driver" ]] || continue
        readlink -f "$driver"
    done
'

echo "PSD QEMU probe: copying current checkout into guest"
tar     --exclude=.git     --exclude=build     --exclude=build-hypr     --exclude=build-plugin     -C "$repo_root"     -cf - .     | ssh "${ssh_options[@]}" psd@127.0.0.1         'rm -rf /home/psd/src && mkdir -p /home/psd/src && tar -xf - -C /home/psd/src'

echo "PSD QEMU probe: building PSD inside Ubuntu 26.04 guest"
ssh_guest '
    set -e
    cd /home/psd/src

    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
    cmake --build build --parallel 2
    ctest --test-dir build --output-on-failure

    cmake -S . -B build-hypr -G Ninja         -DCMAKE_BUILD_TYPE=Debug         -DPSD_BUILD_SHELL=OFF         -DPSD_BUILD_HYPRLAND_PLUGIN=ON         -DBUILD_TESTING=OFF
    cmake --build build-hypr --target psd-hyprland-plugin --parallel 2
'

echo "PSD QEMU probe: starting seatd for native guest DRM/KMS"
ssh_guest '
    set -euo pipefail

    sudo systemctl stop seatd.service >/dev/null 2>&1 || true
    sudo systemctl stop psd-seatd.service >/dev/null 2>&1 || true
    sudo rm -f /run/seatd.sock

    sudo systemd-run \
        --unit=psd-seatd \
        --collect \
        --property=Environment=SEATD_VTBOUND=0 \
        /usr/bin/seatd -g video -l debug >/dev/null

    seatd_ready=0
    for _ in $(seq 1 100); do
        if [[ -S /run/seatd.sock ]]; then
            seatd_ready=1
            break
        fi

        if ! sudo systemctl is-active --quiet psd-seatd.service; then
            echo "PSD QEMU probe: seatd exited before its socket became ready" >&2
            sudo journalctl -u psd-seatd.service --no-pager -n 100 >&2 || true
            exit 1
        fi

        sleep 0.1
    done

    if [[ "$seatd_ready" != "1" ]]; then
        echo "PSD QEMU probe: seatd socket did not become ready" >&2
        sudo journalctl -u psd-seatd.service --no-pager -n 100 >&2 || true
        exit 1
    fi

    echo "PSD QEMU probe: seatd ready"
    id
    ls -l /run/seatd.sock /dev/dri /dev/input/event* 2>/dev/null || true
'

echo "PSD QEMU probe: running Hyprland on native virtio DRM/KMS inside VM"
ssh_guest '
    set -euo pipefail
    cd /home/psd/src

    export LIBSEAT_BACKEND=seatd
    export SEATD_VTBOUND=0
    export AQ_TRACE=1
    unset WAYLAND_DISPLAY
    unset DISPLAY
    unset HYPRLAND_HEADLESS_ONLY

    PSD_PROBE_USE_NATIVE_BACKEND=1 \
        bash tests/integration/probe-hyprland-plugin.sh \
            build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so \
            tests/integration/hyprland-headless.conf

    PSD_PROBE_USE_NATIVE_BACKEND=1 \
        bash tests/integration/probe-vm-runtime-session.sh \
            build/psd-shell \
            build-hypr/src/compositor/hyprland-plugin/psd-hyprland-plugin.so \
            tests/integration/hyprland-headless.conf
'

echo "PSD QEMU probe: PASS"
