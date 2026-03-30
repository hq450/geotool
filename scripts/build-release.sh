#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
LOCAL_CACHE_BASE="${LOCAL_CACHE_BASE:-$ROOT_DIR/.zig-cache/release}"
GLOBAL_CACHE_DIR="${GLOBAL_CACHE_DIR:-$ROOT_DIR/.zig-cache/release-global}"

find_latest_zig() {
    local candidates=()
    local path

    if [[ -n "${ZIG:-}" ]]; then
        candidates+=("$ZIG")
    fi
    if command -v zig >/dev/null 2>&1; then
        candidates+=("$(command -v zig)")
    fi
    while IFS= read -r path; do
        candidates+=("$path")
    done < <(find /tmp/zig "$HOME/.local/zig" -maxdepth 3 -type f -name zig 2>/dev/null | sort -V)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "error: Zig not found. Set ZIG=/path/to/zig." >&2
        exit 1
    fi

    printf '%s\n' "${candidates[@]}" | awk 'NF' | tail -n 1
}

require_executable() {
    local path="$1"
    local name="$2"
    if [[ ! -x "$path" ]]; then
        echo "error: ${name} not found or not executable: $path" >&2
        exit 1
    fi
}

require_upx_version() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$("$path" --version | sed -n '1s/^upx //p')"
    if [[ "$actual" != "$expected" ]]; then
        echo "error: expected UPX $expected at $path, got ${actual:-unknown}" >&2
        exit 1
    fi
}

first_non_empty() {
    local value
    for value in "$@"; do
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

build_target() {
    local name="$1"
    local zig_target="$2"
    local cpu="$3"
    local upx_bin="$4"
    local output="$OUT_DIR/geotool-linux-$name"
    local local_cache_dir="$LOCAL_CACHE_BASE/$name"

    mkdir -p "$OUT_DIR" "$local_cache_dir" "$GLOBAL_CACHE_DIR"
    rm -f "$output"

    echo "==> building $name ($zig_target, cpu=$cpu)"
    ZIG_LOCAL_CACHE_DIR="$local_cache_dir" \
    ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE_DIR" \
    "$ZIG_BIN" build-exe "$ROOT_DIR/src/main.zig" \
        -O ReleaseSmall \
        -fstrip \
        -fsingle-threaded \
        -lc \
        -target "$zig_target" \
        -mcpu="$cpu" \
        -femit-bin="$output"

    echo "==> packing $name with $(basename "$(dirname "$upx_bin")")"
    "$upx_bin" --lzma --ultra-brute "$output"

    file "$output"
    stat -c '%n %s bytes' "$output"
}

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=(x86_64 armv5te armv7a armv7hf aarch64)
fi

ZIG_BIN="$(find_latest_zig)"
UPX_424="$(
    first_non_empty \
        "${UPX_4_2_4:-}" \
        "${UPX_424:-}" \
        "$ROOT_DIR/upx-4.2.4-amd64_linux/upx"
)"
UPX_502="$(
    first_non_empty \
        "${UPX_5_0_2:-}" \
        "${UPX_502:-}" \
        "$ROOT_DIR/upx-5.0.2-amd64_linux/upx"
)"

require_executable "$ZIG_BIN" "Zig"
require_executable "$UPX_424" "UPX 4.2.4"
require_executable "$UPX_502" "UPX 5.0.2"
require_upx_version "$UPX_424" "4.2.4"
require_upx_version "$UPX_502" "5.0.2"

echo "Using Zig: $ZIG_BIN ($("$ZIG_BIN" version))"
echo "Using UPX 4.2.4: $UPX_424"
echo "Using UPX 5.0.2: $UPX_502"
echo

for target in "${TARGETS[@]}"; do
    case "$target" in
        x86_64)
            build_target "x86_64" "x86_64-linux-musl" "${X86_64_CPU:-baseline}" "$UPX_502"
            ;;
        armv5te)
            build_target "armv5te" "arm-linux-musleabi" "${ARMV5_CPU:-arm926ej_s}" "$UPX_424"
            ;;
        armv7a)
            build_target "armv7a" "arm-linux-musleabi" "${ARMV7_CPU:-mpcorenovfp}" "$UPX_502"
            ;;
        armv7hf)
            build_target "armv7hf" "arm-linux-musleabihf" "${ARMV7HF_CPU:-cortex_a9}" "$UPX_502"
            ;;
        aarch64)
            build_target "aarch64" "aarch64-linux-musl" "${AARCH64_CPU:-generic}" "$UPX_502"
            ;;
        *)
            echo "error: unsupported target '$target'" >&2
            echo "supported targets: x86_64 armv5te armv7a armv7hf aarch64" >&2
            exit 1
            ;;
    esac
    echo
done

(
    cd "$OUT_DIR"
    sha256sum geotool-linux-* > SHA256SUMS
)

echo "Artifacts written to: $OUT_DIR"
echo "Checksums written to: $OUT_DIR/SHA256SUMS"
