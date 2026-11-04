#!/usr/bin/env bash
# Real cross-compilation smoke; runs inside the built amd64 image, never on Android devices.
set -euo pipefail

if [[ "$(dpkg --print-architecture)" != amd64 ]]; then
    printf 'Skipped Android NDK smoke: this image architecture has no bundled NDK\n'
    exit 0
fi

: "${ANDROID_NDK_HOME:?NDK home is required}"
: "${ANDROID_NDK_VERSION:?NDK version is required}"
toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
test "$(command -v ndk-build)" = "$ANDROID_NDK_HOME/ndk-build"
test "$(command -v aarch64-linux-android28-clang++)" = "$toolchain/aarch64-linux-android28-clang++"
test "$(command -v llvm-readelf)" = "$toolchain/llvm-readelf"
test -f "$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
revision="$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ANDROID_NDK_HOME/source.properties")"
test "$revision" = "$ANDROID_NDK_VERSION"
ndk-build --version
aarch64-linux-android28-clang++ --version

scratch_root="$(realpath -e -- "${TMPDIR:-/tmp}")"
work="$(mktemp -d "${scratch_root%/}/dsh-ndk-smoke.XXXXXXXX")"
work="$(realpath -e -- "$work")"
cleanup() {
    case "$work" in
        "${scratch_root%/}"/dsh-ndk-smoke.*) rm -rf -- "${work:?}" ;;
        *) printf 'Refusing to clean unexpected NDK smoke path\n' >&2; return 1 ;;
    esac
}
trap cleanup EXIT

aarch64-linux-android28-clang++ -std=c++20 -shared -fPIC -static-libstdc++ \
    -Wl,-z,max-page-size=16384 -x c++ - -o "$work/libndk-smoke.so" <<'CPP'
#include <jni.h>
#include <atomic>
#ifndef __aarch64__
#error Expected Android arm64 code generation
#endif
static_assert(__ANDROID_API__ == 28);
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM*, void*) {
    std::atomic<jint> version{JNI_VERSION_1_6};
    return version.load();
}
CPP

llvm-readelf --file-header --dyn-syms "$work/libndk-smoke.so" > "$work/elf.txt"
grep -E 'Type:[[:space:]]+DYN' "$work/elf.txt"
grep -E 'Machine:[[:space:]]+AArch64' "$work/elf.txt"
grep -F 'JNI_OnLoad' "$work/elf.txt"
printf 'Verified NDK %s: C++20 Android arm64/API 28 JNI shared library\n' "$ANDROID_NDK_VERSION"
