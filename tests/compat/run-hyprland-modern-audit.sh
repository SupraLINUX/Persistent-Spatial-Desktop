#!/usr/bin/env bash
set -e
set -u
set -o pipefail

HYPRLAND_TAG="${HYPRLAND_TAG:-v0.56.2}"
ROOT="${RUNNER_TEMP:-/tmp}/psd-hyprland-modern-audit"
REPORT_DIR="$ROOT/report"
SRC_DIR="$ROOT/src"
BUILD_DIR="$ROOT/build"
PREFIX="$ROOT/prefix"
TOOLS_PREFIX="$ROOT/tools-prefix"

rm -rf "$ROOT"
mkdir -p "$REPORT_DIR" "$SRC_DIR" "$BUILD_DIR" "$PREFIX" "$TOOLS_PREFIX"

exec > >(tee "$REPORT_DIR/full-audit.log") 2>&1

section() {
  printf '\n===== %s =====\n' "$*"
}

record_status() {
  printf '%s=%s\n' "$1" "$2" >> "$REPORT_DIR/status.env"
}

apt_update_retry() {
  local attempt
  for attempt in 1 2 3; do
    if apt-get -o Acquire::Retries=3 update; then
      return 0
    fi
    printf 'apt update attempt %s failed; refreshing again\n' "$attempt" >&2
    sleep $((attempt * 2))
  done
  return 1
}

apt_install_retry() {
  local attempt
  for attempt in 1 2 3; do
    if DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y --no-install-recommends "$@"; then
      return 0
    fi
    printf 'apt install attempt %s failed; refreshing indexes before retry\n' "$attempt" >&2
    apt_update_retry || true
    sleep $((attempt * 2))
  done
  return 1
}

apt_build_dep_retry() {
  local attempt
  for attempt in 1 2 3; do
    if DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 build-dep -y hyprland; then
      return 0
    fi
    printf 'apt build-dep attempt %s failed; refreshing indexes before retry\n' "$attempt" >&2
    apt_update_retry || true
    sleep $((attempt * 2))
  done
  return 1
}

pkg_version() {
  local module="$1"
  if pkg-config --exists "$module" 2>/dev/null; then
    pkg-config --modversion "$module"
  else
    printf 'MISSING'
  fi
}

check_min() {
  local module="$1"
  local minimum="$2"
  local class="$3"
  local version
  version="$(pkg_version "$module")"
  local result="missing"
  if [[ "$version" != "MISSING" ]]; then
    if dpkg --compare-versions "$version" ge "$minimum"; then
      result="pass"
    else
      result="too-old"
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$module" "$version" "$minimum" "$class" "$result" >> "$REPORT_DIR/dependency-minima.tsv"
}

install_available_packages() {
  local available=()
  local missing=()
  local p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
      available+=("$p")
    else
      missing+=("$p")
    fi
  done

  printf '%s\n' "${available[@]}" > "$REPORT_DIR/available-extra-build-packages.txt"
  printf '%s\n' "${missing[@]}" > "$REPORT_DIR/missing-extra-build-packages.txt"

  if (("${#available[@]}" > 0)); then
    apt_install_retry "${available[@]}"
  fi
}

build_component() {
  local name="$1"
  local repo_url="$2"
  local ref="$3"
  local src="$SRC_DIR/$name"
  local build="$BUILD_DIR/$name"

  section "Build isolated component: $name $ref"

  rm -rf "$src" "$build"
  if ! git clone --quiet --filter=blob:none --no-checkout "$repo_url" "$src"; then
    printf 'clone failed: %s %s\n' "$repo_url" "$ref" | tee "$REPORT_DIR/$name.failure"
    return 1
  fi
  if ! git -C "$src" fetch --quiet --depth 1 origin "$ref" ||
     ! git -C "$src" checkout --quiet --detach FETCH_HEAD ||
     ! git -C "$src" submodule update --init --recursive --depth 1; then
    printf 'checkout failed: %s %s\n' "$repo_url" "$ref" | tee "$REPORT_DIR/$name.failure"
    return 1
  fi

  if ! cmake -S "$src" -B "$build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DBUILD_TESTING=OFF \
      -DINSTALL_TESTS=OFF \
      >"$REPORT_DIR/$name-configure.log" 2>&1; then
    cat "$REPORT_DIR/$name-configure.log"
    printf 'configure failed\n' | tee "$REPORT_DIR/$name.failure"
    return 1
  fi

  if ! cmake --build "$build" --parallel 2 >"$REPORT_DIR/$name-build.log" 2>&1; then
    cat "$REPORT_DIR/$name-build.log"
    printf 'build failed\n' | tee "$REPORT_DIR/$name.failure"
    return 1
  fi

  if ! cmake --install "$build" >"$REPORT_DIR/$name-install.log" 2>&1; then
    cat "$REPORT_DIR/$name-install.log"
    printf 'install failed\n' | tee "$REPORT_DIR/$name.failure"
    return 1
  fi

  printf 'PASS\n' | tee "$REPORT_DIR/$name.result"
  return 0
}

build_wayland_toolchain_overlay() {
  local version="1.25.0"
  local src="$SRC_DIR/wayland-$version"
  local build="$BUILD_DIR/wayland-$version"

  section "Build-only toolchain: Wayland $version scanner"

  rm -rf "$src" "$build"
  if ! git clone --quiet --depth 1 --branch "$version" \
      https://gitlab.freedesktop.org/wayland/wayland.git "$src"; then
    printf 'clone failed: wayland %s\n' "$version" | tee "$REPORT_DIR/wayland-toolchain.failure"
    return 1
  fi

  if ! meson setup "$build" "$src" \
      --prefix="$TOOLS_PREFIX" \
      --libdir=lib \
      -Ddocumentation=false \
      -Dtests=false \
      >"$REPORT_DIR/wayland-toolchain-configure.log" 2>&1; then
    cat "$REPORT_DIR/wayland-toolchain-configure.log"
    return 1
  fi

  if ! meson compile -C "$build" >"$REPORT_DIR/wayland-toolchain-build.log" 2>&1 ||
     ! meson install -C "$build" >"$REPORT_DIR/wayland-toolchain-install.log" 2>&1; then
    cat "$REPORT_DIR/wayland-toolchain-build.log" 2>/dev/null || true
    cat "$REPORT_DIR/wayland-toolchain-install.log" 2>/dev/null || true
    return 1
  fi

  "$TOOLS_PREFIX/bin/wayland-scanner" --version > "$REPORT_DIR/wayland-toolchain-version.txt" 2>&1 || true
  printf 'PASS\n' | tee "$REPORT_DIR/wayland-toolchain.result"
  return 0
}
build_wayland_protocols_overlay() {
  local version="1.49"
  local src="$SRC_DIR/wayland-protocols-$version"
  local build="$BUILD_DIR/wayland-protocols-$version"
  local saved_path="$PATH"
  local saved_pkg_config_path="${PKG_CONFIG_PATH:-}"

  section "Build-only overlay: wayland-protocols $version"

  rm -rf "$src" "$build"
  if ! git clone --quiet --depth 1 --branch "$version" \
      https://gitlab.freedesktop.org/wayland/wayland-protocols.git "$src"; then
    printf 'clone failed: wayland-protocols %s\n' "$version" | tee "$REPORT_DIR/wayland-protocols.failure"
    return 1
  fi

  export PATH="$TOOLS_PREFIX/bin:$PATH"
  export PKG_CONFIG_PATH="$TOOLS_PREFIX/lib/pkgconfig:$TOOLS_PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"

  if ! meson setup "$build" "$src" \
      --prefix="$PREFIX" \
      --libdir=lib \
      >"$REPORT_DIR/wayland-protocols-configure.log" 2>&1; then
    cat "$REPORT_DIR/wayland-protocols-configure.log"
    export PATH="$saved_path"
    export PKG_CONFIG_PATH="$saved_pkg_config_path"
    return 1
  fi

  if ! meson install -C "$build" >"$REPORT_DIR/wayland-protocols-install.log" 2>&1; then
    cat "$REPORT_DIR/wayland-protocols-install.log"
    export PATH="$saved_path"
    export PKG_CONFIG_PATH="$saved_pkg_config_path"
    return 1
  fi

  export PATH="$saved_path"
  export PKG_CONFIG_PATH="$saved_pkg_config_path"

  find "$PREFIX" -maxdepth 5 \( -type f -o -type l \) | grep -E "wayland-protocols|pkgconfig/wayland-protocols\.pc" | sort > "$REPORT_DIR/wayland-protocols-overlay-files.txt" || true
  printf 'PASS\n' | tee "$REPORT_DIR/wayland-protocols.result"
  return 0
}
section "Environment"
cat /etc/os-release
uname -a
cmake --version 2>/dev/null || true
c++ --version 2>/dev/null | head -n 1 || true

section "Enable Ubuntu source repositories"
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
  cp /etc/apt/sources.list.d/ubuntu.sources "$REPORT_DIR/ubuntu.sources.before"
  sed -i -E 's/^Types:[[:space:]]+deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
  cp /etc/apt/sources.list.d/ubuntu.sources "$REPORT_DIR/ubuntu.sources.after"
fi

apt_update_retry
record_status INFRA_APT_INDEX_READY pass

section "Install baseline tooling"
apt_install_retry \
  apt-utils \
  binutils \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  dpkg-dev \
  file \
  git \
  jq \
  meson \
  ninja-build \
  pkgconf \
  python3

section "Install Ubuntu 26.04 Hyprland build dependencies"
set +e
apt_build_dep_retry >"$REPORT_DIR/apt-build-dep-hyprland.log" 2>&1
build_dep_rc=$?
set -e
record_status APT_BUILD_DEP_HYPRLAND_RC "$build_dep_rc"
cat "$REPORT_DIR/apt-build-dep-hyprland.log"
if [[ "$build_dep_rc" -ne 0 ]]; then
  record_status INFRA_APT_BUILD_DEP_READY fail
  printf 'Persistent Ubuntu mirror/package-index failure prevented a valid compatibility test.\n' >&2
  exit 2
fi
record_status INFRA_APT_BUILD_DEP_READY pass

section "Install additional generic dependencies when Ubuntu provides them"
install_available_packages \
  glslang-dev \
  glslang-tools \
  hwdata \
  libdisplay-info-dev \
  libdrm-dev \
  libeis-dev \
  libffi-dev \
  libgbm-dev \
  libgl-dev \
  libgles-dev \
  libglib2.0-dev \
  libinput-dev \
  libjpeg-dev \
  liblcms2-dev \
  liblua5.5-dev \
  libmagic-dev \
  libmuparser-dev \
  libpango1.0-dev \
  libpng-dev \
  libpugixml-dev \
  libre2-dev \
  librsvg2-dev \
  libseat-dev \
  libtomlplusplus-dev \
  libudev-dev \
  libwayland-dev \
  libwebp-dev \
  libxcb-composite0-dev \
  libxcb-errors-dev \
  libxcb-icccm4-dev \
  libxcb-render0-dev \
  libxcb-res0-dev \
  libxcb-xfixes0-dev \
  libxkbcommon-dev \
  libxcursor-dev \
  libzip-dev \
  uuid-dev \
  wayland-protocols

section "Toolchain sanity after APT"
for cmd in git cmake c++ pkg-config meson ninja; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'required tool missing after APT: %s\n' "$cmd" >&2
    record_status INFRA_TOOLCHAIN_READY fail
    exit 2
  fi
done
record_status INFRA_TOOLCHAIN_READY pass
printf 'git=%s\n' "$(command -v git)"
printf 'cmake=%s\n' "$(command -v cmake)"
printf 'pkg-config=%s\n' "$(command -v pkg-config)"

section "Ubuntu package inventory"
apt-cache policy hyprland hyprland-dev > "$REPORT_DIR/apt-policy-hyprland.txt" 2>&1 || true
apt-cache search hypr > "$REPORT_DIR/apt-search-hypr.txt" 2>&1 || true
dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$REPORT_DIR/dpkg-installed.tsv"

cat "$REPORT_DIR/apt-policy-hyprland.txt"
printf '\nHypr-related archive packages:\n'
cat "$REPORT_DIR/apt-search-hypr.txt"

section "Dependency minimum audit for Hyprland $HYPRLAND_TAG"
printf 'module\tubuntu_version\tminimum\tclass\tresult\n' > "$REPORT_DIR/dependency-minima.tsv"
check_min aquamarine 0.9.3 hypr-stack
check_min hyprlang 0.6.7 hypr-stack
check_min hyprcursor 0.1.7 hypr-stack
check_min hyprutils 0.14.0 hypr-stack
check_min hyprgraphics 0.5.1 hypr-stack
check_min xkbcommon 1.11.0 ubuntu-runtime
check_min wayland-server 1.22.91 ubuntu-runtime
check_min wayland-protocols 1.49 build-only
check_min libinput 1.29 ubuntu-runtime

lua_version="MISSING"
for lua_module in lua55 lua5.5 lua-55 lua-5.5 lua; do
  if pkg-config --exists "$lua_module" 2>/dev/null; then
    candidate="$(pkg-config --modversion "$lua_module")"
    if dpkg --compare-versions "$candidate" ge 5.5 && dpkg --compare-versions "$candidate" lt 5.6; then
      lua_version="$candidate"
      break
    fi
  fi
done
lua_result="missing"
if [[ "$lua_version" != "MISSING" ]]; then
  lua_result="pass"
fi
printf 'lua-5.5\t%s\t5.5,<5.6\tubuntu-base\t%s\n' "$lua_version" "$lua_result" >> "$REPORT_DIR/dependency-minima.tsv"

scanner_version="MISSING"
if command -v hyprwayland-scanner >/dev/null 2>&1; then
  scanner_version="$(hyprwayland-scanner --version 2>/dev/null | head -n 1 || true)"
fi
printf 'hyprwayland-scanner\t%s\t0.3.10\thypr-stack\tinfo\n' "$scanner_version" >> "$REPORT_DIR/dependency-minima.tsv"

column -t -s $'\t' "$REPORT_DIR/dependency-minima.tsv" || cat "$REPORT_DIR/dependency-minima.tsv"

core_blockers="$(awk -F '\t' 'NR>1 && $4=="ubuntu-base" && $5!="pass" {print $1 "=" $2 " (needs " $3 ")"}' "$REPORT_DIR/dependency-minima.tsv")"
if [[ -n "$core_blockers" ]]; then
  printf '%s\n' "$core_blockers" > "$REPORT_DIR/core-ubuntu-blockers.txt"
  record_status CORE_UBUNTU_MINIMA pass_with_blockers
else
  : > "$REPORT_DIR/core-ubuntu-blockers.txt"
  record_status CORE_UBUNTU_MINIMA pass
fi

section "Stock Ubuntu build attempt: Hyprland $HYPRLAND_TAG"
HYPR_SRC="$SRC_DIR/Hyprland-stock"
git clone --quiet --depth 1 --branch "$HYPRLAND_TAG" --recursive https://github.com/hyprwm/Hyprland.git "$HYPR_SRC"

set +e
cmake -S "$HYPR_SRC" -B "$BUILD_DIR/Hyprland-stock" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DNO_HYPRPM=ON \
  -DNO_UWSM=ON \
  >"$REPORT_DIR/stock-configure.log" 2>&1
stock_configure_rc=$?
set -e

if [[ "$stock_configure_rc" -eq 0 ]]; then
  stock_configure_status="pass"
  set +e
  cmake --build "$BUILD_DIR/Hyprland-stock" --parallel 2 >"$REPORT_DIR/stock-build.log" 2>&1
  stock_build_rc=$?
  set -e
  if [[ "$stock_build_rc" -eq 0 ]]; then
    stock_build_status="pass"
  else
    stock_build_status="fail"
  fi
else
  stock_configure_status="fail"
  stock_build_rc=125
  stock_build_status="not-run"
fi

record_status STOCK_CONFIGURE "$stock_configure_status"
record_status STOCK_BUILD "$stock_build_status"

printf '\n--- stock configure log ---\n'
cat "$REPORT_DIR/stock-configure.log"
if [[ -f "$REPORT_DIR/stock-build.log" ]]; then
  printf '\n--- stock build log tail ---\n'
  tail -n 200 "$REPORT_DIR/stock-build.log"
fi

section "Build isolated Hypr stack into $PREFIX"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
# The Ubuntu archive carries an older hyprutils SONAME. Force every private
# Hypr component to resolve -lhyprutils from PREFIX at link time, not only at
# pkg-config discovery time.
export LIBRARY_PATH="$PREFIX/lib:${LIBRARY_PATH:-}"
export LDFLAGS="-L$PREFIX/lib ${LDFLAGS:-}"

isolated_stack_status="pass"

# v0.56.2 flake.lock is the compatibility reference for the Hypr ecosystem.
# Use the exact revisions upstream shipped together instead of arbitrary minima.
# Wayland 1.25 is used only as a private build-tool provider for protocol 1.49.
# Runtime linking is intentionally returned to Ubuntu 26.04 Wayland afterwards.
if ! build_wayland_toolchain_overlay; then
  isolated_stack_status="fail:wayland-toolchain-overlay"
elif ! build_wayland_protocols_overlay; then
  isolated_stack_status="fail:wayland-protocols-overlay"
fi

components=(
  "hyprwayland-scanner|https://github.com/hyprwm/hyprwayland-scanner.git|b8632713a6beaf28b56f2a7b0ab2fb7088dbb404"
  "hyprutils|https://github.com/hyprwm/hyprutils.git|5a7b8cf221914ce4714407950e4ffbdddcd8b66f"
  "hyprlang|https://github.com/hyprwm/hyprlang.git|090117506ddc3d7f26e650ff344d378c2ec329cc"
  "hyprcursor|https://github.com/hyprwm/hyprcursor.git|39435900785d0c560c6ae8777d29f28617d031ef"
  "hyprgraphics|https://github.com/hyprwm/hyprgraphics.git|8699c38f0e4a1ca3bfc84f84ba020509ced1f133"
  "aquamarine|https://github.com/hyprwm/aquamarine.git|1a10fe26a9f7d989c359e6a9ea61aa2e44d06c36"
  "hyprwire|https://github.com/hyprwm/hyprwire.git|7d935bb54674aa0fbd327d2a6888bd0630079ed0"
)

if [[ "$isolated_stack_status" == "pass" ]]; then
  for spec in "${components[@]}"; do
    IFS='|' read -r name repo_url ref <<< "$spec"
    if ! build_component "$name" "$repo_url" "$ref"; then
      isolated_stack_status="fail:$name"
      break
    fi
  done
fi
record_status ISOLATED_HYPR_STACK "$isolated_stack_status"

isolated_hyprland_status="not-run"
if [[ "$isolated_stack_status" == "pass" ]]; then
  section "Build Hyprland $HYPRLAND_TAG against isolated Hypr stack + stock Ubuntu base"

  HYPR_ISO_SRC="$SRC_DIR/Hyprland-isolated"
  git clone --quiet --depth 1 --branch "$HYPRLAND_TAG" --recursive https://github.com/hyprwm/Hyprland.git "$HYPR_ISO_SRC"

  section "Apply Ubuntu 26.04 / GCC 15 source-compatibility patch"
  compat_patch="$GITHUB_WORKSPACE/tests/compat/patches/hyprland-v0.56.2-gcc15-ranges-starts-with.patch"
  if patch --dry-run -d "$HYPR_ISO_SRC" -p1 < "$compat_patch" >"$REPORT_DIR/gcc15-compat-patch-dry-run.log" 2>&1; then
    patch -d "$HYPR_ISO_SRC" -p1 < "$compat_patch" >"$REPORT_DIR/gcc15-compat-patch.log" 2>&1
    record_status HYPRLAND_GCC15_COMPAT_PATCH applied
  else
    cat "$REPORT_DIR/gcc15-compat-patch-dry-run.log"
    record_status HYPRLAND_GCC15_COMPAT_PATCH failed
    isolated_hyprland_status="patch-fail"
  fi

  set +e
  cmake -S "$HYPR_ISO_SRC" -B "$BUILD_DIR/Hyprland-isolated" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DNO_HYPRPM=ON \
    -DNO_UWSM=ON \
    >"$REPORT_DIR/isolated-hyprland-configure.log" 2>&1
  isolated_configure_rc=$?
  set -e

  if [[ "$isolated_hyprland_status" == "patch-fail" ]]; then
    isolated_configure_rc=125
  fi

  if [[ "$isolated_hyprland_status" != "patch-fail" && "$isolated_configure_rc" -eq 0 ]]; then
    set +e
    cmake --build "$BUILD_DIR/Hyprland-isolated" --parallel 2 >"$REPORT_DIR/isolated-hyprland-build.log" 2>&1
    isolated_build_rc=$?
    set -e
    if [[ "$isolated_build_rc" -eq 0 ]]; then
      isolated_hyprland_status="built"
      cmake --install "$BUILD_DIR/Hyprland-isolated" > "$REPORT_DIR/isolated-hyprland-install.log" 2>&1 || true
      LD_LIBRARY_PATH="$PREFIX/lib" ldd "$BUILD_DIR/Hyprland-isolated/Hyprland" > "$REPORT_DIR/isolated-hyprland-ldd.txt" 2>&1 || true
      "$BUILD_DIR/Hyprland-isolated/Hyprland" --version > "$REPORT_DIR/isolated-hyprland-version.txt" 2>&1 || true

      private_hyprutils_soname="$(readelf -d "$PREFIX/lib/libhyprutils.so" | sed -n 's/.*SONAME.*\\[\\(.*\\)\\].*/\\1/p' | head -n1)"
      mapfile -t resolved_hyprutils < <(awk '/libhyprutils\\.so\./ {print $1}' "$REPORT_DIR/isolated-hyprland-ldd.txt" | sort -u)
      {
        echo "expected=$private_hyprutils_soname"
        printf 'resolved=%s\\n' "${resolved_hyprutils[@]}"
      } > "$REPORT_DIR/hyprutils-abi-coherence.txt"

      if [[ -z "$private_hyprutils_soname" || "${#resolved_hyprutils[@]}" -ne 1 || "${resolved_hyprutils[0]}" != "$private_hyprutils_soname" ]]; then
        record_status HYPRUTILS_ABI_COHERENCE fail
        isolated_hyprland_status="abi-mix-fail"
      else
        record_status HYPRUTILS_ABI_COHERENCE pass
      fi
      find "$PREFIX" -maxdepth 5 \( -type f -o -type l \) | sort > "$REPORT_DIR/isolated-prefix-files.txt" || true
      if grep -Eq "wayland-protocols|/share/wayland-protocols" "$REPORT_DIR/isolated-hyprland-ldd.txt"; then
        record_status WAYLAND_PROTOCOLS_RUNTIME_LINK unexpected
      else
        record_status WAYLAND_PROTOCOLS_RUNTIME_LINK none
      fi
      if [[ "$isolated_hyprland_status" == "built" ]]; then
        isolated_hyprland_status="pass"
      fi
    else
      isolated_hyprland_status="build-fail"
    fi
  else
    isolated_hyprland_status="configure-fail"
  fi
fi
record_status ISOLATED_HYPRLAND "$isolated_hyprland_status"

if [[ -f "$REPORT_DIR/isolated-hyprland-configure.log" ]]; then
  printf '\n--- isolated Hyprland configure log ---\n'
  cat "$REPORT_DIR/isolated-hyprland-configure.log"
fi
if [[ -f "$REPORT_DIR/isolated-hyprland-build.log" ]]; then
  printf '\n--- isolated Hyprland build log tail ---\n'
  tail -n 200 "$REPORT_DIR/isolated-hyprland-build.log"
fi
if [[ -f "$REPORT_DIR/isolated-hyprland-ldd.txt" ]]; then
  printf '\n--- isolated Hyprland ldd ---\n'
  cat "$REPORT_DIR/isolated-hyprland-ldd.txt"
fi

section "Archive reverse-dependency audit"
: > "$REPORT_DIR/hypr-reverse-dependencies.txt"
while read -r package _; do
  [[ -n "$package" ]] || continue
  printf '\n### %s\n' "$package" >> "$REPORT_DIR/hypr-reverse-dependencies.txt"
  apt-cache rdepends "$package" >> "$REPORT_DIR/hypr-reverse-dependencies.txt" 2>&1 || true
done < <(apt-cache search hypr | awk '{print $1}' | sort -u)

cat "$REPORT_DIR/hypr-reverse-dependencies.txt"

section "Representative Ubuntu application resolver simulation"
representative_apps=(krita libreoffice vlc inkscape gimp dolphin nautilus)
available_apps=()
missing_apps=()
for app in "${representative_apps[@]}"; do
  if apt-cache show "$app" >/dev/null 2>&1; then
    available_apps+=("$app")
  else
    missing_apps+=("$app")
  fi
done
printf '%s\n' "${available_apps[@]}" > "$REPORT_DIR/representative-apps-available.txt"
printf '%s\n' "${missing_apps[@]}" > "$REPORT_DIR/representative-apps-missing.txt"

resolver_status="not-run"
resolver_removals=0
if (("${#available_apps[@]}" > 0)); then
  set +e
  apt-get -s install "${available_apps[@]}" > "$REPORT_DIR/representative-apps-apt-sim.log" 2>&1
  resolver_rc=$?
  set -e
  resolver_removals="$(grep -c '^Remv ' "$REPORT_DIR/representative-apps-apt-sim.log" 2>/dev/null || true)"
  if [[ "$resolver_rc" -eq 0 && "$resolver_removals" -eq 0 ]]; then
    resolver_status="pass"
  else
    resolver_status="fail"
  fi
fi
record_status REPRESENTATIVE_APT_RESOLVER "$resolver_status"
record_status REPRESENTATIVE_APT_REMOVALS "$resolver_removals"
cat "$REPORT_DIR/representative-apps-apt-sim.log" 2>/dev/null || true

section "Generate summary"
{
  echo "# Hyprland modern-on-Ubuntu-26.04 compatibility audit"
  echo
  echo "- Hyprland tag: \`$HYPRLAND_TAG\`"
  echo "- Ubuntu image: \`ubuntu:26.04\`"
  echo "- Stock configure: **$stock_configure_status**"
  echo "- Stock build: **$stock_build_status**"
  echo "- Isolated Hypr stack: **$isolated_stack_status**"
  echo "- Hyprland with isolated Hypr stack: **$isolated_hyprland_status**"
  if [[ -f "$REPORT_DIR/wayland-toolchain-version.txt" ]]; then
    echo "- Private build scanner: **$(cat "$REPORT_DIR/wayland-toolchain-version.txt" | head -n 1)**"
  fi
  echo "- Representative Ubuntu APT simulation: **$resolver_status**"
  echo "- Packages APT wanted to remove in representative simulation: **$resolver_removals**"
  echo
  echo "## Required versions vs Ubuntu"
  echo
  echo '| module | Ubuntu | minimum | ownership | result |'
  echo '|---|---:|---:|---|---|'
  awk -F '\t' 'NR>1 {printf "| %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5}' "$REPORT_DIR/dependency-minima.tsv"
  echo
  echo "## Core Ubuntu blockers"
  if [[ -s "$REPORT_DIR/core-ubuntu-blockers.txt" ]]; then
    sed 's/^/- /' "$REPORT_DIR/core-ubuntu-blockers.txt"
  else
    echo "- None detected by the declared minimum-version audit."
  fi
  echo
  echo "## Interpretation"
  if [[ "$stock_build_status" == "pass" ]]; then
    echo "- Hyprland $HYPRLAND_TAG builds directly against the Ubuntu 26.04 dependency set used by this job."
  elif [[ "$isolated_hyprland_status" == "pass" ]]; then
    echo "- Stock Ubuntu build inputs are insufficient, but Hyprland $HYPRLAND_TAG builds with upstream pinned Hypr revisions plus an isolated build-only wayland-protocols 1.49 overlay."
  else
    echo "- The isolated Hypr-only replacement was not sufficient. Inspect logs for a core Ubuntu dependency or source/API incompatibility."
  fi
  if [[ "$resolver_status" == "pass" ]]; then
    echo "- Installing representative Ubuntu applications remains solvable without removals in this diagnostic environment."
  fi
  echo
  echo "This experiment does not claim production packaging safety. It distinguishes build-time dependency pressure from Debian package replacement semantics."
} | tee "$REPORT_DIR/SUMMARY.md"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$REPORT_DIR/SUMMARY.md" >> "$GITHUB_STEP_SUMMARY"
fi

section "Final diagnostic status"
cat "$REPORT_DIR/status.env"

if [[ "$isolated_hyprland_status" == "pass" ]]; then
  exit 0
fi

exit 1
