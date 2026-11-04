#!/bin/sh
# Sourced by entrypoint and login shells; append NDK tools without shadowing host tools.
# Missing NDK directories (including the arm64 image) are intentionally ignored.
if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -n "${ANDROID_NDK_VERSION:-}" ]; then
    ANDROID_NDK_HOME="${ANDROID_HOME:-/opt/android-sdk}/ndk/$ANDROID_NDK_VERSION"
    export ANDROID_NDK_HOME
fi

if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    case "$ANDROID_NDK_HOME" in
        /*) ;;
        *) printf 'ANDROID_NDK_HOME must be an absolute path\n' >&2; return 1 ;;
    esac
    case "$ANDROID_NDK_HOME" in
        *:*) printf 'ANDROID_NDK_HOME must not contain a PATH separator\n' >&2; return 1 ;;
    esac
    # Replace only image-owned NDK entries; preserve the order of host/user tools.
    # Split explicitly instead of using unquoted IFS expansion (paths may contain spaces/globs).
    dsh_ndk_remaining="${PATH:-}"
    dsh_ndk_clean=''
    dsh_ndk_kept=0
    while :; do
        case "$dsh_ndk_remaining" in
            *:*) dsh_ndk_entry="${dsh_ndk_remaining%%:*}"; dsh_ndk_remaining="${dsh_ndk_remaining#*:}"; dsh_ndk_more=1 ;;
            *) dsh_ndk_entry="$dsh_ndk_remaining"; dsh_ndk_more=0 ;;
        esac
        case "$dsh_ndk_entry" in
            /opt/android-sdk/ndk/*) ;;
            *)
                if [ "$dsh_ndk_kept" = 1 ]; then
                    dsh_ndk_clean="$dsh_ndk_clean:$dsh_ndk_entry"
                else
                    dsh_ndk_clean="$dsh_ndk_entry"
                    dsh_ndk_kept=1
                fi
                ;;
        esac
        [ "$dsh_ndk_more" = 1 ] || break
    done
    PATH="$dsh_ndk_clean"
    unset dsh_ndk_remaining dsh_ndk_clean dsh_ndk_kept dsh_ndk_entry dsh_ndk_more

    for dsh_ndk_dir in \
        "$ANDROID_NDK_HOME" \
        "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"; do
        [ -d "$dsh_ndk_dir" ] || continue
        case ":${PATH:-}:" in
            *":$dsh_ndk_dir:"*) ;;
            *) PATH="${PATH:+$PATH:}$dsh_ndk_dir" ;;
        esac
    done
    unset dsh_ndk_dir
fi
export PATH
