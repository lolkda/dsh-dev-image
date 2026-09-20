#!/usr/bin/env bash
# Portable CLI regression tests; Linux ownership/capabilities are covered separately.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/bin"
# shellcheck disable=SC2016 # 这些变量由外部 DSH 测试替身执行时展开。
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "$CALLS"\nexit "${PLUGIN_EXIT:-0}"\n' > "$TMP/bin/dsh"
chmod +x "$TMP/bin/dsh"

passed=0
failed=0

run_case() {
    local name="$1"
    shift
    # 条件里的函数调用会让 Bash 忽略函数内部的 errexit；必须先单独执行。
    set +e
    ( set -e; "$@" )
    local status=$?
    set -e
    if (( status == 0 )); then
        printf 'ok - %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'not ok - %s\n' "$name"
        failed=$((failed + 1))
    fi
}

setup_case() {
    CASE_DIR="$(mktemp -d "$TMP/case.XXXXXX")"
    export APP_DIR="$CASE_DIR/work space"
    export DSH_HOME="$APP_DIR/.dsh"
    export CALLS="$CASE_DIR/calls"
    export PATH="$TMP/bin:$PATH"
    export DSH_PLUGINS=''
    export DSH_PLUGINS_REQUIRED=1
    unset AGENT_UID AGENT_GID DSH_ENTRYPOINT_DROPPED PLUGIN_EXIT
    unset CARGO_HOME GOPATH GOMODCACHE GOCACHE PIP_CACHE_DIR npm_config_cache
    unset MAVEN_CONFIG GRADLE_USER_HOME UV_CACHE_DIR
    export HOME="$CASE_DIR/home"
    mkdir -p "$APP_DIR"
    : > "$CALLS"
}

creates_state_before_command() {
    setup_case
    bash "$ROOT/entrypoint.sh" bash -c 'test -d "$DSH_HOME" && test -d "$APP_DIR/.cache/npm"'
}

uses_workspace_for_relative_commands() {
    setup_case
    (cd "$CASE_DIR" && bash "$ROOT/entrypoint.sh" bash -c 'printf ready > command-output')
    test -f "$APP_DIR/command-output"
}

empty_command_is_error() {
    setup_case
    if bash "$ROOT/entrypoint.sh" > "$CASE_DIR/output" 2>&1; then
        printf 'Expected an empty command to fail\n' >&2
        return 1
    fi
}

plugin_failure_blocks_command() {
    setup_case
    export DSH_PLUGINS='@example/plugin@1.0.0' PLUGIN_EXIT=23
    if bash "$ROOT/entrypoint.sh" bash -c 'touch "$APP_DIR/started"' > "$CASE_DIR/output" 2>&1; then
        printf 'Expected a required plugin failure to fail\n' >&2
        return 1
    fi
    test ! -e "$APP_DIR/started"
}

optional_plugin_failure_allows_command() {
    setup_case
    export DSH_PLUGINS='@example/plugin@1.0.0' PLUGIN_EXIT=23 DSH_PLUGINS_REQUIRED=0
    bash "$ROOT/entrypoint.sh" bash -c 'touch "$APP_DIR/started"' > "$CASE_DIR/output" 2>&1
    test -f "$APP_DIR/started"
}

plugin_specs_do_not_expand_globs() {
    setup_case
    export DSH_PLUGINS='plugin-*'
    touch "$APP_DIR/plugin-local"
    (cd "$APP_DIR" && bash "$ROOT/entrypoint.sh" true)
    test "$(tail -n 1 "$CALLS")" = 'plugin-*'
}

invalid_uid_is_rejected() {
    setup_case
    export AGENT_UID=0
    if bash "$ROOT/entrypoint.sh" true > "$CASE_DIR/output" 2>&1; then
        printf 'Expected UID 0 to be rejected\n' >&2
        return 1
    fi
}

invalid_boolean_is_rejected() {
    setup_case
    export DSH_PLUGINS_REQUIRED=oops
    if bash "$ROOT/entrypoint.sh" true > "$CASE_DIR/output" 2>&1; then
        printf 'Expected an invalid boolean to be rejected\n' >&2
        return 1
    fi
}

file_instead_of_state_directory_is_rejected() {
    setup_case
    export DSH_PLUGINS='@example/plugin@1.0.0'
    touch "$DSH_HOME"
    if bash "$ROOT/entrypoint.sh" true > "$CASE_DIR/output" 2>&1; then
        printf 'Expected a state path occupied by a file to fail\n' >&2
        return 1
    fi
    test ! -s "$CALLS"
}

plugin_option_is_rejected() {
    setup_case
    export DSH_PLUGINS='--ignore-scripts'
    if bash "$ROOT/entrypoint.sh" true > "$CASE_DIR/output" 2>&1; then
        printf 'Expected a package-manager flag not to be accepted as a plugin\n' >&2
        return 1
    fi
    test ! -s "$CALLS"
}

quoted_workspace_path_is_supported() {
    setup_case
    export APP_DIR="$CASE_DIR/owner's project" DSH_HOME="$CASE_DIR/owner's project/.dsh"
    mkdir -p "$APP_DIR"
    bash "$ROOT/entrypoint.sh" bash -c 'test -d "$DSH_HOME" && test "$PWD" = "$APP_DIR"'
}

command_exit_status_is_preserved() {
    setup_case
    local status=0
    bash "$ROOT/entrypoint.sh" bash -c 'exit 37' || status=$?
    test "$status" = 37
}

unset_plugins_is_supported() {
    setup_case
    unset DSH_PLUGINS
    bash "$ROOT/entrypoint.sh" true
    test ! -s "$CALLS"
}

multiline_plugins_are_preserved() {
    setup_case
    export DSH_PLUGINS=$'@example/one@1\n@example/two@2'
    bash "$ROOT/entrypoint.sh" true
    test "$(tail -n 1 "$CALLS")" = '@example/two@2'
}

web_command_uses_selected_profile() {
    setup_case
    export DSH_PROFILE=custom-web
    bash "$ROOT/entrypoint.sh" dsh web --port 9000
    printf '%s\n' --profile custom-web --port 9000 > "$CASE_DIR/expected"
    cmp "$CASE_DIR/expected" "$CALLS"
}

home_is_inside_the_mount() {
    setup_case
    bash "$ROOT/entrypoint.sh" bash -c 'test "$HOME" = "$APP_DIR/.home" && test -d "$HOME"'
}

home_survives_a_new_entrypoint_process() {
    setup_case
    bash "$ROOT/entrypoint.sh" bash -c 'printf fixture-state > "$HOME/persistence-marker"'
    bash "$ROOT/entrypoint.sh" bash -c 'test "$(< "$HOME/persistence-marker")" = fixture-state'
    test -f "$APP_DIR/.home/persistence-marker"
}

existing_home_configuration_is_not_overwritten() {
    setup_case
    mkdir -p "$APP_DIR/.home"
    printf user-configuration > "$APP_DIR/.home/.bashrc"
    bash "$ROOT/entrypoint.sh" true
    test "$(< "$APP_DIR/.home/.bashrc")" = user-configuration
}

home_file_is_rejected_before_plugins() {
    setup_case
    export DSH_PLUGINS='@example/plugin@1.0.0'
    touch "$APP_DIR/.home"
    if bash "$ROOT/entrypoint.sh" true > "$CASE_DIR/output" 2>&1; then
        printf 'Expected a file at the persistent HOME path to fail\n' >&2
        return 1
    fi
    test ! -s "$CALLS"
}

run_case 'place HOME inside the persistent mount' home_is_inside_the_mount
run_case 'preserve HOME state across entrypoint processes' home_survives_a_new_entrypoint_process
run_case 'preserve an existing HOME configuration' existing_home_configuration_is_not_overwritten
run_case 'reject a file at HOME before installing plugins' home_file_is_rejected_before_plugins
run_case 'use the selected profile for the default web command' web_command_uses_selected_profile
run_case 'allow DSH_PLUGINS to be unset' unset_plugins_is_supported
run_case 'support newline-separated plugin specs' multiline_plugins_are_preserved
run_case 'reject root as the requested agent UID' invalid_uid_is_rejected
run_case 'validate boolean configuration instead of silently ignoring it' invalid_boolean_is_rejected
run_case 'reject a file at the state directory before attempting plugins' file_instead_of_state_directory_is_rejected
run_case 'reject package-manager options passed as plugin names' plugin_option_is_rejected
run_case 'support spaces and quotes in the workspace path' quoted_workspace_path_is_supported
run_case 'preserve the command exit status' command_exit_status_is_preserved
run_case 'create state directories before the command as a non-root user' creates_state_before_command
run_case 'run commands from APP_DIR' uses_workspace_for_relative_commands
run_case 'reject an empty command' empty_command_is_error
run_case 'required plugin failure prevents command execution' plugin_failure_blocks_command
run_case 'optional plugin failure allows command execution' optional_plugin_failure_allows_command
run_case 'preserve literal plugin specs instead of expanding globs' plugin_specs_do_not_expand_globs

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
