#!/bin/sh
set -eu

umask 077

PROGRAM="herdr-config"
BEGIN_MARKER="# >>> herdr-config managed commands >>>"
END_MARKER="# <<< herdr-config managed commands <<<"
DRY_RUN=0
COMMAND="install"

usage() {
  cat <<'EOF'
Usage: install.sh [install|doctor|restore] [--dry-run]

Commands:
  install   Install pinned plugins and merge the portable Herdr config (default)
  doctor    Check Herdr, config, keybindings, and pinned plugins without changes
  restore   Restore config and herdr-lazy files from the latest snapshot

Environment:
  HERDR_BIN                Herdr executable (default: herdr)
  HERDR_CONFIG_HOME        Herdr config directory override
  HERDR_CONFIG_STATE_HOME  Installer state directory override
EOF
}

for arg in "$@"; do
  case "$arg" in
    install|doctor|restore) COMMAND="$arg" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "$PROGRAM: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

HERDR_BIN=${HERDR_BIN:-herdr}
if [ -n "${HERDR_CONFIG_HOME:-}" ]; then
  CONFIG_DIR=$HERDR_CONFIG_HOME
else
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
fi
if [ -n "${HERDR_CONFIG_STATE_HOME:-}" ]; then
  STATE_DIR=$HERDR_CONFIG_STATE_HOME
else
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-config"
fi
CONFIG_FILE="$CONFIG_DIR/config.toml"
SNAPSHOTS_DIR="$STATE_DIR/snapshots"
LOCK_DIR="$STATE_DIR/operation.lock"
LOCK_HELD=0
TMP_ROOT=""
SNAPSHOT_DIR=""
SNAPSHOT_STAGING=""
PRE_PLUGINS=""
VALIDATION_FILE=""

desired_plugins() {
  cat <<'EOF'
natori-hrj/herdr-lazy|herdr-lazy|6a2132b74283b586dbe8b995f2aacd47255d6d8b
jeffarese/herdr-bar|herdr-bar|01cc0620ec743ee7a62a561551b59d9be81bd563
smarzban/herdr-file-viewer|herdr-file-viewer|71d4c1c3706e7958c714789b035a99d949620a9e
persiyanov/herdr-reviewr|persiyanov.reviewr|792b4b31475ddbf263ee4d421a984e7418031506
iurysza/herdr-tab-smart-rename|tab-smart-rename|a580a9ef248357ea9d85cf0f2131acb2e3fae240
EOF
}

plugin_list_body() {
  desired_plugins | while IFS='|' read -r repo _id commit; do
    printf '%s@%s\n' "$repo" "$commit"
  done
}

say() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "$SNAPSHOT_STAGING" ] && [ -d "$SNAPSHOT_STAGING" ]; then
    rm -rf "$SNAPSHOT_STAGING"
  fi
  if [ -n "$VALIDATION_FILE" ] && [ -f "$VALIDATION_FILE" ]; then
    rm -f "$VALIDATION_FILE"
  fi
  if [ "$LOCK_HELD" -eq 1 ] && [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
  fi
}
handle_signal() {
  signal_exit=$1
  trap - HUP INT TERM
  if [ -n "$SNAPSHOT_DIR" ] && [ -f "$SNAPSHOT_DIR/complete" ]; then
    rollback "interrupted by signal"
  fi
  exit "$signal_exit"
}

trap cleanup 0
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

require_runtime() {
  command -v "$HERDR_BIN" >/dev/null 2>&1 || die "Herdr is required but '$HERDR_BIN' was not found in PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  herdr_version=$(herdr_version)
  version_supported "$herdr_version" || die "Herdr 0.7.5 or newer is required (found ${herdr_version:-unknown})"
}

herdr_version() {
  "$HERDR_BIN" --version 2>/dev/null | awk 'NR == 1 {print $2}'
}

version_supported() {
  python3 - "$1" <<'PY'
import re, sys
match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
raise SystemExit(0 if match and tuple(map(int, match.groups())) >= (0, 7, 5) else 1)
PY
}

make_tmp() {
  [ -n "$TMP_ROOT" ] && return
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/herdr-config.XXXXXX")
}

acquire_lock() {
  [ "$DRY_RUN" -eq 1 ] && return
  mkdir -p "$STATE_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another operation may be running; inspect the lock before removing it: $LOCK_DIR"
  fi
  LOCK_HELD=1
  printf '%s\n' "pid=$$" "started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$LOCK_DIR/owner"
}

capture_plugins() {
  output=$1
  "$HERDR_BIN" plugin list --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in d.get("result", {}).get("plugins", []):
    s = p.get("source") or {}
    print("|".join([
        p.get("plugin_id", ""), s.get("owner", ""), s.get("repo", ""),
        s.get("resolved_commit", ""), "1" if p.get("enabled", True) else "0"
    ]))
' > "$output"
}

snapshot_current() {
  [ "$DRY_RUN" -eq 1 ] && return
  stamp=$(date -u '+%Y%m%dT%H%M%SZ')-$$
  snapshot_final="$SNAPSHOTS_DIR/$stamp"
  SNAPSHOT_STAGING="$SNAPSHOTS_DIR/.$stamp.incomplete"
  SNAPSHOT_DIR="$SNAPSHOT_STAGING"
  mkdir -p "$SNAPSHOT_DIR"
  if [ -e "$CONFIG_FILE" ]; then
    [ ! -L "$CONFIG_FILE" ] || die "refusing to modify symlink: $CONFIG_FILE"
    cp -p "$CONFIG_FILE" "$SNAPSHOT_DIR/config.toml"
    : > "$SNAPSHOT_DIR/config.existed"
  fi
  cp "$PRE_PLUGINS" "$SNAPSHOT_DIR/plugins.before"
  if "$HERDR_BIN" plugin config-dir herdr-lazy > "$TMP_ROOT/lazy-dir" 2>/dev/null; then
    lazy_dir=$(sed -n '1p' "$TMP_ROOT/lazy-dir")
    if [ -n "$lazy_dir" ] && [ -d "$lazy_dir" ]; then
      for file in plugins.list plugins.lock; do
        if [ -f "$lazy_dir/$file" ]; then
          cp -p "$lazy_dir/$file" "$SNAPSHOT_DIR/$file"
          : > "$SNAPSHOT_DIR/$file.existed"
        fi
      done
      printf '%s\n' "$lazy_dir" > "$SNAPSHOT_DIR/lazy-dir"
    fi
  fi
  : > "$SNAPSHOT_DIR/complete"
  mv "$SNAPSHOT_DIR" "$snapshot_final"
  SNAPSHOT_DIR="$snapshot_final"
  SNAPSHOT_STAGING=""
}

restore_config_from() {
  snapshot=$1
  mkdir -p "$CONFIG_DIR"
  if [ -f "$snapshot/config.existed" ]; then
    cp -p "$snapshot/config.toml" "$CONFIG_FILE.tmp.$$"
    mv "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"
  else
    rm -f "$CONFIG_FILE"
  fi
  if [ -f "$snapshot/lazy-dir" ]; then
    lazy_dir=$(sed -n '1p' "$snapshot/lazy-dir")
    mkdir -p "$lazy_dir"
    for file in plugins.list plugins.lock; do
      if [ -f "$snapshot/$file.existed" ]; then
        cp -p "$snapshot/$file" "$lazy_dir/$file.tmp.$$"
        mv "$lazy_dir/$file.tmp.$$" "$lazy_dir/$file"
      else
        rm -f "$lazy_dir/$file"
      fi
    done
  fi
}

rollback_plugins() {
  [ -n "$PRE_PLUGINS" ] || return 0
  current="$TMP_ROOT/plugins.current"
  capture_plugins "$current" 2>/dev/null || return 1
  errors="$TMP_ROOT/rollback-errors"
  : > "$errors"
  desired_plugins | while IFS='|' read -r _repo id _commit; do
    before=$(awk -F'|' -v id="$id" '$1 == id {print; exit}' "$PRE_PLUGINS")
    now=$(awk -F'|' -v id="$id" '$1 == id {print; exit}' "$current")
    [ "$before" != "$now" ] || continue
    if [ -z "$before" ] && [ -n "$now" ]; then
      "$HERDR_BIN" plugin uninstall "$id" >/dev/null 2>&1 || printf '%s\n' "$id uninstall" >> "$errors"
    elif [ -n "$before" ] && [ -n "$now" ]; then
      old_owner=$(printf '%s\n' "$before" | awk -F'|' '{print $2}')
      old_repo=$(printf '%s\n' "$before" | awk -F'|' '{print $3}')
      old_commit=$(printf '%s\n' "$before" | awk -F'|' '{print $4}')
      old_enabled=$(printf '%s\n' "$before" | awk -F'|' '{print $5}')
      if [ -n "$old_owner" ] && [ -n "$old_repo" ] && [ -n "$old_commit" ]; then
        if ! "$HERDR_BIN" plugin install "$old_owner/$old_repo" --ref "$old_commit" --yes >/dev/null 2>&1; then
          printf '%s\n' "$id reinstall" >> "$errors"
          continue
        fi
        if [ "$old_enabled" = "0" ]; then
          "$HERDR_BIN" plugin disable "$id" >/dev/null 2>&1 || printf '%s\n' "$id disable" >> "$errors"
        else
          "$HERDR_BIN" plugin enable "$id" >/dev/null 2>&1 || printf '%s\n' "$id enable" >> "$errors"
        fi
      else
        printf '%s\n' "$id unsupported-source" >> "$errors"
      fi
    fi
  done
  capture_plugins "$TMP_ROOT/plugins.after-rollback" 2>/dev/null || return 1
  desired_plugins | while IFS='|' read -r _repo id _commit; do
    before=$(awk -F'|' -v id="$id" '$1 == id {print; exit}' "$PRE_PLUGINS")
    after=$(awk -F'|' -v id="$id" '$1 == id {print; exit}' "$TMP_ROOT/plugins.after-rollback")
    [ "$before" = "$after" ] || printf '%s\n' "$id mismatch" >> "$errors"
  done
  [ ! -s "$errors" ]
}

config_matches_snapshot() {
  snapshot=$1
  if [ -f "$snapshot/config.existed" ]; then
    [ -f "$CONFIG_FILE" ] && cmp -s "$snapshot/config.toml" "$CONFIG_FILE"
  else
    [ ! -e "$CONFIG_FILE" ]
  fi
}

lazy_files_match_snapshot() {
  snapshot=$1
  [ -f "$snapshot/lazy-dir" ] || return 0
  lazy_dir=$(sed -n '1p' "$snapshot/lazy-dir")
  for file in plugins.list plugins.lock; do
    if [ -f "$snapshot/$file.existed" ]; then
      [ -f "$lazy_dir/$file" ] && cmp -s "$snapshot/$file" "$lazy_dir/$file" || return 1
    else
      [ ! -e "$lazy_dir/$file" ] || return 1
    fi
  done
}

rollback() {
  reason=$1
  say "Install failed: $reason"
  if [ -n "$SNAPSHOT_DIR" ] && [ -d "$SNAPSHOT_DIR" ]; then
    rollback_ok=1
    restore_config_from "$SNAPSHOT_DIR" || rollback_ok=0
    config_matches_snapshot "$SNAPSHOT_DIR" || rollback_ok=0
    lazy_files_match_snapshot "$SNAPSHOT_DIR" || rollback_ok=0
    rollback_plugins || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
      say "Rollback completed from snapshot: $SNAPSHOT_DIR"
    else
      say "WARNING: rollback was incomplete; inspect snapshot: $SNAPSHOT_DIR" >&2
    fi
  fi
  exit 1
}

merge_config() {
  target=$1
  python3 - "$target" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
import os, re, stat, sys, tempfile

path, begin, end = sys.argv[1:]
if os.path.islink(path):
    raise SystemExit(f"refusing to modify symlink: {path}")
try:
    original = open(path, encoding="utf-8").read()
    mode = stat.S_IMODE(os.stat(path).st_mode)
except FileNotFoundError:
    original, mode = "", 0o600

managed_values = {
    "keys": {
        "prefix": '"ctrl+b"',
        "new_tab": '"prefix+c"',
        "close_tab": '"prefix+shift+x"',
        "new_workspace": '"prefix+shift+n"',
        "close_workspace": '"prefix+shift+d"',
        "previous_agent": '"prefix+up"',
        "next_agent": '"prefix+down"',
        "focus_agent": '"prefix+alt+1..9"',
    },
    "ui": {
        "agent_panel_sort": '"priority"',
        "prompt_new_tab_name": "false",
    },
}
commands = [
    ("prefix+k", "herdr-bar.open", "open command bar"),
    ("prefix+f", "herdr-file-viewer.open-file-viewer", None),
    ("prefix+shift+f", "herdr-file-viewer.open-file-viewer-tab", None),
    ("cmd+r", "persiyanov.reviewr.toggle", None),
]

def strip_marked(text):
    pattern = re.compile(r"(?ms)^" + re.escape(begin) + r"\n.*?^" + re.escape(end) + r"\n?")
    return pattern.sub("", text)

def strip_owned_command_blocks(text):
    owned = {(key, command) for key, command, _ in commands}
    lines = text.splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        if lines[i].strip() != "[[keys.command]]":
            out.append(lines[i]); i += 1; continue
        j = i + 1
        while j < len(lines) and not re.match(r"^\s*\[", lines[j]):
            j += 1
        block = "".join(lines[i:j])
        command_match = re.search(r'^\s*command\s*=\s*"([^"]+)"', block, re.M)
        key_match = re.search(r'^\s*key\s*=\s*"([^"]+)"', block, re.M)
        pair = (key_match.group(1), command_match.group(1)) if key_match and command_match else None
        if pair not in owned:
            out.extend(lines[i:j])
        i = j
    return "".join(out)

def upsert_table(text, table, values):
    lines = text.splitlines(keepends=True)
    header = f"[{table}]"
    start = next((i for i, line in enumerate(lines) if line.strip() == header), None)
    if start is None:
        if text and not text.endswith("\n"):
            text += "\n"
        text += ("\n" if text else "") + header + "\n"
        for key, value in values.items():
            text += f"{key} = {value}\n"
        return text
    finish = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^\s*\[", lines[i]):
            finish = i; break
    for key, value in values.items():
        pattern = re.compile(r"^(\s*)" + re.escape(key) + r"\s*=.*?(\r?\n)?$")
        found = False
        for i in range(start + 1, finish):
            if pattern.match(lines[i]):
                newline = "\r\n" if lines[i].endswith("\r\n") else "\n"
                lines[i] = f"{key} = {value}{newline}"
                found = True; break
        if not found:
            lines.insert(finish, f"{key} = {value}\n")
            finish += 1
    return "".join(lines)

body = strip_owned_command_blocks(strip_marked(original)).rstrip() + "\n"
for table, values in managed_values.items():
    body = upsert_table(body, table, values)

# Refuse to shadow an unrelated existing keybinding.
for key, _, _ in commands:
    if re.search(r'^\s*key\s*=\s*"' + re.escape(key) + r'"', body, re.M):
        raise SystemExit(f"keybinding already owned by another command: {key}")

block = ["", begin]
for key, command, description in commands:
    block += ["[[keys.command]]", f'key = "{key}"', 'type = "plugin_action"', f'command = "{command}"']
    if description:
        block.append(f'description = "{description}"')
    block.append("")
block.append(end)
body = body.rstrip() + "\n" + "\n".join(block) + "\n"

if body == original:
    raise SystemExit(0)
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
fd, temp = tempfile.mkstemp(prefix=".config.toml.", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(body); f.flush(); os.fsync(f.fileno())
    os.chmod(temp, mode)
    os.replace(temp, path)
finally:
    if os.path.exists(temp): os.unlink(temp)
PY
}

install_plugins() {
  current=$1
  desired_plugins | while IFS='|' read -r repo id commit; do
    installed=$(awk -F'|' -v id="$id" '$1 == id {print $4; exit}' "$current")
    enabled=$(awk -F'|' -v id="$id" '$1 == id {print $5; exit}' "$current")
    installed_repo=$(awk -F'|' -v id="$id" '$1 == id {print $2 "/" $3; exit}' "$current")
    if [ "$installed_repo" = "$repo" ] && [ "$installed" = "$commit" ] && [ "$enabled" = "1" ]; then
      say "ok      $repo@$commit"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      say "would install $repo@$commit"
      continue
    fi
    say "install $repo@$commit"
    "$HERDR_BIN" plugin install "$repo" --ref "$commit" --yes || exit 23
    capture_plugins "$current"
  done
}

write_lazy_files() {
  [ "$DRY_RUN" -eq 1 ] && { say "would write herdr-lazy plugins.list and plugins.lock"; return; }
  lazy_dir=$("$HERDR_BIN" plugin config-dir herdr-lazy) || return 1
  [ -n "$lazy_dir" ] || return 1
  if [ -n "$SNAPSHOT_DIR" ] && [ ! -f "$SNAPSHOT_DIR/lazy-dir" ]; then
    printf '%s\n' "$lazy_dir" > "$SNAPSHOT_DIR/lazy-dir"
  fi
  mkdir -p "$lazy_dir"
  for file in plugins.list plugins.lock; do
    temp="$lazy_dir/.$file.tmp.$$"
    {
      printf '# Managed by herdr-config. Exact commit pins.\n'
      plugin_list_body
    } > "$temp"
    mv "$temp" "$lazy_dir/$file"
  done
}

managed_config_valid() {
  python3 - "$CONFIG_FILE" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
import re, sys
path, begin, end = sys.argv[1:]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    raise SystemExit(1)
if text.splitlines().count(begin) != 1 or text.splitlines().count(end) != 1:
    raise SystemExit(1)
managed = text.split(begin, 1)[1].split(end, 1)[0]
expected_commands = {
    ("prefix+k", "herdr-bar.open"),
    ("prefix+f", "herdr-file-viewer.open-file-viewer"),
    ("prefix+shift+f", "herdr-file-viewer.open-file-viewer-tab"),
    ("cmd+r", "persiyanov.reviewr.toggle"),
}
found = set()
for block in managed.split("[[keys.command]]")[1:]:
    key = re.search(r'^\s*key\s*=\s*"([^"]+)"', block, re.M)
    command = re.search(r'^\s*command\s*=\s*"([^"]+)"', block, re.M)
    if key and command:
        found.add((key.group(1), command.group(1)))
if found != expected_commands:
    raise SystemExit(1)

expected_values = {
    "keys": {
        "prefix": '"ctrl+b"', "new_tab": '"prefix+c"',
        "close_tab": '"prefix+shift+x"', "new_workspace": '"prefix+shift+n"',
        "close_workspace": '"prefix+shift+d"', "previous_agent": '"prefix+up"',
        "next_agent": '"prefix+down"', "focus_agent": '"prefix+alt+1..9"',
    },
    "ui": {"agent_panel_sort": '"priority"', "prompt_new_tab_name": "false"},
}
sections = {name: {} for name in expected_values}
current = None
for line in text.splitlines():
    header = re.match(r'^\s*\[([^\[\]]+)\]\s*$', line)
    if header:
        current = header.group(1)
        continue
    if current in sections:
        item = re.match(r'^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$', line)
        if item:
            sections[current][item.group(1)] = item.group(2)
for section, values in expected_values.items():
    for key, value in values.items():
        if sections[section].get(key) != value:
            raise SystemExit(1)
PY
}

doctor() {
  problems=0
  if ! command -v "$HERDR_BIN" >/dev/null 2>&1; then
    say "FAIL Herdr executable not found: $HERDR_BIN"
    return 1
  fi
  current_version=$(herdr_version || true)
  if command -v python3 >/dev/null 2>&1 && version_supported "$current_version"; then
    say "OK   Herdr $current_version"
  else
    say "FAIL Herdr 0.7.5+ required; found ${current_version:-unknown}"
    problems=$((problems + 1))
  fi
  if HERDR_CONFIG_PATH="$CONFIG_FILE" "$HERDR_BIN" config check >/dev/null 2>&1; then say "OK   config parses"; else say "FAIL config check"; problems=$((problems + 1)); fi
  if [ -f "$CONFIG_FILE" ]; then
    if managed_config_valid; then say "OK   managed settings and keybindings"; else say "FAIL managed settings or keybindings"; problems=$((problems + 1)); fi
  else
    say "FAIL config missing: $CONFIG_FILE"; problems=$((problems + 1))
  fi
  make_tmp
  if capture_plugins "$TMP_ROOT/doctor.plugins" 2>/dev/null; then
    desired_plugins | while IFS='|' read -r repo id commit; do
      installed=$(awk -F'|' -v id="$id" '$1 == id {print $4; exit}' "$TMP_ROOT/doctor.plugins")
      enabled=$(awk -F'|' -v id="$id" '$1 == id {print $5; exit}' "$TMP_ROOT/doctor.plugins")
      installed_repo=$(awk -F'|' -v id="$id" '$1 == id {print $2 "/" $3; exit}' "$TMP_ROOT/doctor.plugins")
      if [ "$installed_repo" = "$repo" ] && [ "$installed" = "$commit" ] && [ "$enabled" = "1" ]; then say "OK   $repo"; else say "FAIL $repo expected enabled@$commit found ${installed_repo:-missing}@${installed:-missing} enabled=${enabled:-missing}"; fi
    done
    missing=$(desired_plugins | while IFS='|' read -r repo id commit; do
      installed=$(awk -F'|' -v id="$id" '$1 == id {print $4; exit}' "$TMP_ROOT/doctor.plugins")
      enabled=$(awk -F'|' -v id="$id" '$1 == id {print $5; exit}' "$TMP_ROOT/doctor.plugins")
      installed_repo=$(awk -F'|' -v id="$id" '$1 == id {print $2 "/" $3; exit}' "$TMP_ROOT/doctor.plugins")
      [ "$installed_repo" = "$repo" ] && [ "$installed" = "$commit" ] && [ "$enabled" = "1" ] || printf x
    done)
    [ -z "$missing" ] || problems=$((problems + 1))
  else
    say "FAIL cannot read Herdr plugin registry"; problems=$((problems + 1))
  fi
  [ "$problems" -eq 0 ]
}

restore_latest() {
  [ "$DRY_RUN" -eq 0 ] || { say "would restore the latest snapshot from $SNAPSHOTS_DIR"; return; }
  latest=""
  for candidate in "$SNAPSHOTS_DIR"/*; do
    [ -d "$candidate" ] || continue
    [ -f "$candidate/complete" ] || continue
    latest=$candidate
  done
  [ -n "$latest" ] || die "no snapshot available"
  if [ -f "$latest/config.existed" ]; then
    mkdir -p "$CONFIG_DIR"
    VALIDATION_FILE=$(mktemp "$CONFIG_DIR/.herdr-config-restore-check.XXXXXX")
    cp "$latest/config.toml" "$VALIDATION_FILE"
    if ! HERDR_CONFIG_PATH="$VALIDATION_FILE" "$HERDR_BIN" config check >/dev/null 2>&1; then
      die "latest snapshot contains a config that is invalid for this Herdr version: $latest"
    fi
    rm -f "$VALIDATION_FILE"
    VALIDATION_FILE=""
  fi
  restore_config_from "$latest"
  HERDR_CONFIG_PATH="$CONFIG_FILE" "$HERDR_BIN" config check >/dev/null 2>&1 || die "restored config does not pass herdr config check"
  "$HERDR_BIN" server reload-config >/dev/null 2>&1 || true
  say "Restored snapshot: $latest"
}

case "$COMMAND" in
  doctor)
    doctor
    ;;
  restore)
    require_runtime
    acquire_lock
    restore_latest
    ;;
  install)
    require_runtime
    make_tmp
    capture_plugins "$TMP_ROOT/plugins.before" || die "could not read Herdr plugin registry"
    PRE_PLUGINS="$TMP_ROOT/plugins.before"
    if [ "$DRY_RUN" -eq 1 ]; then
      [ ! -L "$CONFIG_FILE" ] || die "refusing to modify symlink: $CONFIG_FILE"
      HERDR_CONFIG_PATH="$CONFIG_FILE" "$HERDR_BIN" config check >/dev/null 2>&1 || die "existing Herdr config is invalid"
      preview="$TMP_ROOT/config.preview.toml"
      if [ -f "$CONFIG_FILE" ]; then cp "$CONFIG_FILE" "$preview"; fi
      merge_config "$preview" || die "config merge would fail"
      install_plugins "$PRE_PLUGINS" || die "could not calculate plugin changes"
      say "would merge portable settings into $CONFIG_FILE"
      write_lazy_files
      exit 0
    fi
    acquire_lock
    HERDR_CONFIG_PATH="$CONFIG_FILE" "$HERDR_BIN" config check || die "existing Herdr config is invalid; no changes were made"
    snapshot_current
    cp "$PRE_PLUGINS" "$TMP_ROOT/plugins.current"
    if ! install_plugins "$TMP_ROOT/plugins.current"; then rollback "plugin installation failed"; fi
    if ! merge_config "$CONFIG_FILE"; then rollback "config merge failed"; fi
    if ! HERDR_CONFIG_PATH="$CONFIG_FILE" "$HERDR_BIN" config check; then rollback "herdr config check failed"; fi
    if ! write_lazy_files; then rollback "could not write herdr-lazy configuration"; fi
    "$HERDR_BIN" server reload-config >/dev/null 2>&1 || true
    say "Installed successfully. Snapshot: $SNAPSHOT_DIR"
    say "Smart Rename setup: herdr plugin action invoke configure-ai --plugin tab-smart-rename"
    say "Smart Rename start: herdr plugin action invoke start --plugin tab-smart-rename"
    ;;
esac
