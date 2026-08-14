#!/usr/bin/env bash

set -eu

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TESTS_DIR/.." && pwd)
INSTALLER="$REPO_DIR/install.sh"
FAKE_BIN="$TESTS_DIR/fake-bin"

BEGIN_MARKER='# >>> herdr-config managed commands >>>'
END_MARKER='# <<< herdr-config managed commands <<<'

pass_count=0
fail_count=0
current_test=''
current_sandbox=''

fail() {
  printf '# %s: %s\n' "$current_test" "$*" >&2
  : > "$current_sandbox/assertion-failed"
  return 1
}

assert_file_exists() {
  [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_file_missing() {
  [ ! -e "$1" ] || fail "expected path not to exist: $1"
}

assert_files_equal() {
  cmp -s "$1" "$2" || fail "files differ: $1 and $2"
}

assert_equals() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_log_contains() {
  grep -F -- "$1" "$FAKE_HERDR_LOG" >/dev/null 2>&1 || \
    fail "fake herdr log does not contain: $1"
}

count_fixed() {
  awk -v needle="$2" 'index($0, needle) { count++ } END { print count + 0 }' "$1"
}

setup_sandbox() {
  current_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/herdr-config-test.XXXXXX")
  export FAKE_SANDBOX_ROOT="$current_sandbox"
  export HOME="$current_sandbox/home"
  export XDG_CONFIG_HOME="$current_sandbox/xdg-config"
  export XDG_STATE_HOME="$current_sandbox/xdg-state"
  export HERDR_CONFIG_HOME="$XDG_CONFIG_HOME/herdr"
  export HERDR_CONFIG_STATE_HOME="$XDG_STATE_HOME/herdr-config"
  export FAKE_HERDR_LOG="$current_sandbox/fake-herdr.log"
  export FAKE_HERDR_STATE="$current_sandbox/fake-herdr-state"
  export PATH="$FAKE_BIN:$ORIGINAL_PATH"
  unset FAKE_HERDR_FAIL_PLUGIN_INSTALL FAKE_HERDR_FAIL_PLUGIN_INSTALL_AT
  unset FAKE_HERDR_FAIL_CONFIG_CHECK FAKE_HERDR_FAIL_RELOAD
  unset FAKE_HERDR_VERSION
  mkdir -p "$HOME" "$HERDR_CONFIG_HOME"
  : > "$FAKE_HERDR_LOG"
}

teardown_sandbox() {
  if [ -n "$current_sandbox" ] && [ -d "$current_sandbox" ]; then
    rm -rf -- "$current_sandbox"
  fi
  current_sandbox=''
}

run_test() {
  current_test="$1"
  setup_sandbox
  test_status=0
  ( "$2" ) || test_status=$?
  if [ "$test_status" -eq 0 ] && [ ! -e "$current_sandbox/assertion-failed" ]; then
    printf 'ok - %s\n' "$current_test"
    pass_count=$((pass_count + 1))
  else
    printf 'not ok - %s\n' "$current_test" >&2
    fail_count=$((fail_count + 1))
  fi
  teardown_sandbox
}

test_fresh_install() {
  "$INSTALLER" >/dev/null || fail 'default install command failed'

  config="$HERDR_CONFIG_HOME/config.toml"
  assert_file_exists "$config"
  assert_equals "$(count_fixed "$config" "$BEGIN_MARKER")" '1'
  assert_equals "$(count_fixed "$config" "$END_MARKER")" '1'
  assert_file_missing "$HERDR_CONFIG_HOME/provider.env"
  assert_log_contains 'config check'
  grep -F '[ui.sidebar.session_footer]' "$config" >/dev/null || fail 'agent usage footer section missing'
  grep -F 'tokens = ["$agent_usage"]' "$config" >/dev/null || fail 'agent usage footer token missing'
  grep -F 'action = "ram4.codex-usage.open"' "$config" >/dev/null || fail 'agent usage footer action missing'
  assert_log_contains 'plugin install ram4-dev/herdr-codex-usage --ref eebd90913b83788240d20e597383b8a6ae462b18 --yes'

  plugin_lines=$(grep -c '^plugin install ' "$FAKE_HERDR_LOG" || true)
  [ "$plugin_lines" -gt 0 ] || fail 'expected at least one pinned plugin installation'
  while IFS= read -r line; do
    case "$line" in
      *' --ref '*' --yes'*) ;;
      *) fail "plugin installation is not pinned and non-interactive: $line" ;;
    esac
  done < <(grep '^plugin install ' "$FAKE_HERDR_LOG")
}

test_idempotent_rerun() {
  "$INSTALLER" install >/dev/null || fail 'first install failed'
  config="$HERDR_CONFIG_HOME/config.toml"
  cp "$config" "$current_sandbox/first-config.toml"

  "$INSTALLER" install >/dev/null || fail 'second install failed'

  assert_files_equal "$current_sandbox/first-config.toml" "$config"
  assert_equals "$(count_fixed "$config" "$BEGIN_MARKER")" '1'
  assert_equals "$(count_fixed "$config" "$END_MARKER")" '1'
}

test_rejects_herdr_0_8() {
  export FAKE_HERDR_VERSION=0.8.0
  if "$INSTALLER" install --dry-run >"$current_sandbox/version.out" 2>&1; then
    fail 'installer unexpectedly accepted Herdr 0.8.0'
  fi
  grep -F 'Herdr 0.9.0 or newer is required' "$current_sandbox/version.out" >/dev/null || \
    fail 'minimum-version failure did not explain the Herdr 0.9.0 requirement'
}

test_preserves_unrelated_config() {
  config="$HERDR_CONFIG_HOME/config.toml"
  printf '%s\n' \
    '# user-owned prefix' \
    '[appearance]' \
    'theme = "custom"' \
    '# user-owned suffix' > "$config"

  "$INSTALLER" install >/dev/null || fail 'install failed'

  grep -F '# user-owned prefix' "$config" >/dev/null || fail 'lost user prefix'
  grep -F '[appearance]' "$config" >/dev/null || fail 'lost user section'
  grep -F 'theme = "custom"' "$config" >/dev/null || fail 'lost user setting'
  grep -F '# user-owned suffix' "$config" >/dev/null || fail 'lost user suffix'
}

test_no_duplicate_managed_block() {
  "$INSTALLER" install >/dev/null || fail 'first install failed'
  "$INSTALLER" install >/dev/null || fail 'second install failed'
  "$INSTALLER" >/dev/null || fail 'default install rerun failed'

  config="$HERDR_CONFIG_HOME/config.toml"
  assert_equals "$(count_fixed "$config" "$BEGIN_MARKER")" '1'
  assert_equals "$(count_fixed "$config" "$END_MARKER")" '1'
}

test_preserves_custom_binding_for_managed_action() {
  config="$HERDR_CONFIG_HOME/config.toml"
  printf '%s\n' \
    '[[keys.command]]' \
    'key = "prefix+z"' \
    'type = "plugin_action"' \
    'command = "herdr-bar.open"' > "$config"

  "$INSTALLER" install >/dev/null || fail 'install failed'

  grep -F 'key = "prefix+z"' "$config" >/dev/null || fail 'custom binding was removed'
  assert_equals "$(count_fixed "$config" 'command = "herdr-bar.open"')" '2'
}

test_dry_run_has_no_writes() {
  config="$HERDR_CONFIG_HOME/config.toml"
  rmdir "$HERDR_CONFIG_HOME"

  "$INSTALLER" install --dry-run >/dev/null || fail 'dry-run failed'

  assert_file_missing "$HERDR_CONFIG_HOME"
  assert_file_missing "$HERDR_CONFIG_STATE_HOME"
  if grep -E '^plugin install |^server reload-config' "$FAKE_HERDR_LOG" >/dev/null; then
    fail 'dry-run invoked a mutating herdr command'
  fi
}

test_dry_run_detects_binding_conflict() {
  config="$HERDR_CONFIG_HOME/config.toml"
  printf '%s\n' \
    '[[keys.command]]' \
    'key = "prefix+k"' \
    'type = "plugin_action"' \
    'command = "someone-else.open"' > "$config"
  cp "$config" "$current_sandbox/original-config.toml"

  if "$INSTALLER" install --dry-run >"$current_sandbox/dry-run.out" 2>&1; then
    fail 'dry-run unexpectedly accepted a conflicting binding'
  fi

  assert_files_equal "$current_sandbox/original-config.toml" "$config"
  assert_file_missing "$HERDR_CONFIG_STATE_HOME"
}

test_plugin_failure_rolls_back() {
  config="$HERDR_CONFIG_HOME/config.toml"
  printf '%s\n' '# original config' '[user]' 'name = "keep-me"' > "$config"
  cp "$config" "$current_sandbox/original-config.toml"
  export FAKE_HERDR_FAIL_PLUGIN_INSTALL=1

  if "$INSTALLER" install >"$current_sandbox/failure.out" 2>&1; then
    fail 'installer unexpectedly succeeded after plugin failure'
  fi

  assert_files_equal "$current_sandbox/original-config.toml" "$config"
  assert_equals "$(count_fixed "$config" "$BEGIN_MARKER")" '0'
}

test_disabled_plugin_is_enabled() {
  mkdir -p "$FAKE_HERDR_STATE"
  printf '%s\t%s\t0\n' \
    'jeffarese/herdr-bar' \
    '01cc0620ec743ee7a62a561551b59d9be81bd563' \
    > "$FAKE_HERDR_STATE/installed-plugins"

  "$INSTALLER" install >/dev/null || fail 'install failed'

  assert_log_contains 'plugin install jeffarese/herdr-bar --ref 01cc0620ec743ee7a62a561551b59d9be81bd563 --yes'
  grep -F $'jeffarese/herdr-bar\t01cc0620ec743ee7a62a561551b59d9be81bd563\t1' \
    "$FAKE_HERDR_STATE/installed-plugins" >/dev/null || fail 'plugin was not enabled'
}

test_rollback_restores_disabled_state() {
  mkdir -p "$FAKE_HERDR_STATE"
  printf '%s\t%s\t0\n' \
    'jeffarese/herdr-bar' \
    '01cc0620ec743ee7a62a561551b59d9be81bd563' \
    > "$FAKE_HERDR_STATE/installed-plugins"
  export FAKE_HERDR_FAIL_PLUGIN_INSTALL_AT=3

  if "$INSTALLER" install >"$current_sandbox/failure.out" 2>&1; then
    fail 'installer unexpectedly succeeded after plugin failure'
  fi

  grep -F $'jeffarese/herdr-bar\t01cc0620ec743ee7a62a561551b59d9be81bd563\t0' \
    "$FAKE_HERDR_STATE/installed-plugins" >/dev/null || fail 'rollback did not restore disabled state'
}

test_config_failure_rolls_back() {
  config="$HERDR_CONFIG_HOME/config.toml"
  printf '%s\n' '# original config' '[user]' 'name = "keep-me"' > "$config"
  cp "$config" "$current_sandbox/original-config.toml"
  export FAKE_HERDR_FAIL_CONFIG_CHECK=1

  if "$INSTALLER" install >"$current_sandbox/failure.out" 2>&1; then
    fail 'installer unexpectedly succeeded after config validation failure'
  fi

  assert_files_equal "$current_sandbox/original-config.toml" "$config"
  assert_equals "$(count_fixed "$config" "$BEGIN_MARKER")" '0'
}

test_existing_lock_is_preserved() {
  mkdir -p "$HERDR_CONFIG_STATE_HOME/operation.lock"
  printf '%s\n' 'other-process' > "$HERDR_CONFIG_STATE_HOME/operation.lock/owner"

  if "$INSTALLER" install >"$current_sandbox/lock.out" 2>&1; then
    fail 'installer unexpectedly ignored an existing operation lock'
  fi

  assert_file_exists "$HERDR_CONFIG_STATE_HOME/operation.lock/owner"
}

test_restore_latest_snapshot() {
  config="$HERDR_CONFIG_HOME/config.toml"
  printf '%s\n' '# before install' '[user]' 'name = "original"' > "$config"
  cp "$config" "$current_sandbox/original-config.toml"

  "$INSTALLER" install >/dev/null || fail 'install failed'
  printf '%s\n' '# changed later' > "$config"
  "$INSTALLER" restore >/dev/null || fail 'restore failed'

  assert_files_equal "$current_sandbox/original-config.toml" "$config"
}

test_restore_ignores_incomplete_snapshot() {
  config="$HERDR_CONFIG_HOME/config.toml"
  printf '%s\n' '# before install' '[user]' 'name = "original"' > "$config"
  cp "$config" "$current_sandbox/original-config.toml"
  "$INSTALLER" install >/dev/null || fail 'install failed'

  mkdir -p "$HERDR_CONFIG_STATE_HOME/snapshots/zzzz-incomplete"
  printf '%s\n' '# changed later' > "$config"
  "$INSTALLER" restore >/dev/null || fail 'restore failed'

  assert_files_equal "$current_sandbox/original-config.toml" "$config"
}

test_provider_env_is_preserved() {
  provider="$HERDR_CONFIG_HOME/provider.env"
  nested_provider="$HERDR_CONFIG_HOME/tab-smart-rename/provider.env"
  mkdir -p "$(dirname "$nested_provider")"
  printf '%s\n' 'API_KEY=super-secret-root' > "$provider"
  printf '%s\n' 'API_KEY=super-secret-plugin' > "$nested_provider"
  cp "$provider" "$current_sandbox/original-provider.env"
  cp "$nested_provider" "$current_sandbox/original-nested-provider.env"

  "$INSTALLER" install >/dev/null || fail 'install failed'

  assert_files_equal "$current_sandbox/original-provider.env" "$provider"
  assert_files_equal "$current_sandbox/original-nested-provider.env" "$nested_provider"
}

if [ ! -x "$INSTALLER" ]; then
  printf 'install.sh is missing or not executable: %s\n' "$INSTALLER" >&2
  exit 2
fi

ORIGINAL_PATH=$PATH
trap teardown_sandbox EXIT HUP INT TERM

run_test 'fresh install' test_fresh_install
run_test 'idempotent rerun' test_idempotent_rerun
run_test 'rejects Herdr 0.8.x' test_rejects_herdr_0_8
run_test 'preserves unrelated config' test_preserves_unrelated_config
run_test 'does not duplicate managed block' test_no_duplicate_managed_block
run_test 'preserves custom binding for a managed action' test_preserves_custom_binding_for_managed_action
run_test 'dry-run performs no writes' test_dry_run_has_no_writes
run_test 'dry-run detects binding conflicts' test_dry_run_detects_binding_conflict
run_test 'plugin failure rolls config back' test_plugin_failure_rolls_back
run_test 'disabled plugin is enabled' test_disabled_plugin_is_enabled
run_test 'rollback restores disabled plugin state' test_rollback_restores_disabled_state
run_test 'config failure rolls config back' test_config_failure_rolls_back
run_test 'existing operation lock is preserved' test_existing_lock_is_preserved
run_test 'restore uses latest snapshot' test_restore_latest_snapshot
run_test 'restore ignores incomplete snapshots' test_restore_ignores_incomplete_snapshot
run_test 'provider.env is preserved' test_provider_env_is_preserved

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
