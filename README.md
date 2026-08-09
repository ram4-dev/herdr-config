# herdr-config

Reproducible, macOS-first Herdr setup with pinned plugins, portable keybindings,
snapshots, and rollback.

## Status

This repository is under initial development. It currently assumes Herdr 0.7.5 or
newer and Python 3 are already installed. It never exports or overwrites
`tab-smart-rename/provider.env`; API credentials remain local to each machine.

## Install

Install the pinned Herdr setup with:

```sh
curl -fsSL https://raw.githubusercontent.com/ram4-dev/herdr-config/v0.1.0/install.sh | sh
```

For local development:

```sh
./install.sh --dry-run
./install.sh install
./install.sh doctor
./install.sh restore
```

If an operation is killed without allowing cleanup, inspect
`~/.local/state/herdr-config/operation.lock/owner` and confirm that process is no
longer running before removing the stale lock directory.

The installer:

- installs every plugin at an immutable commit;
- merges owned settings while preserving unrelated TOML sections;
- adopts the exact default bindings into its marked block and preserves unrelated bindings;
- writes `plugins.list` and `plugins.lock` for `herdr-lazy`;
- snapshots configuration before mutation;
- rolls back configuration and managed plugin versions after a failed install.

## Managed plugins

- `natori-hrj/herdr-lazy`
- `jeffarese/herdr-bar`
- `smarzban/herdr-file-viewer`
- `persiyanov/herdr-reviewr`
- `iurysza/herdr-tab-smart-rename`

See [plugins.list](plugins.list) and [plugins.lock](plugins.lock) for exact commits.

## Overrides

Tests and advanced installations can override paths without touching the real setup:

```sh
HERDR_BIN=/path/to/herdr \
HERDR_CONFIG_HOME=/tmp/herdr \
HERDR_CONFIG_STATE_HOME=/tmp/herdr-config-state \
./install.sh install
```
