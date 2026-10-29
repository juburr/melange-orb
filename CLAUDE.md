# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, for melange, Chainguard's tool that builds APK packages from declarative YAML pipelines for apko to assemble into distroless images. The orb installs a checksum-verified melange, prepares machines for its bubblewrap runner, and wraps the melange subcommands a pipeline needs: `keygen`, `build`, `test` and `index`.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh

# Tests (offline)
for t in tests/*_test.sh; do bash "$t" || break; done

# Generate SHA-512 checksums (linux amd64 + arm64) for a new melange version
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - `install`, `setup_bubblewrap`, and one command per melange subcommand: `keygen`, `build`, `test`, `index`
- `scripts/` - Shell implementations, included with `<< include(scripts/...) >>`
- `scripts/lib/melange.sh` - Helpers shared by `keygen.sh`, `build.sh`, `test.sh` and `index.sh`. Each of those commands passes it to its step as `SCRIPT_MELANGE_LIB: << include(scripts/lib/melange.sh) >>`, and the script `eval`s it after checking it is set. It only defines functions and has no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version

### Key Implementation Details

**`scripts/install.sh`**: Installs the linux amd64 or arm64 melange build (from `uname -m`) from GitHub releases with SHA-512 checksum verification. It follows the layout every juburr orb's install.sh shares: a tool definition, a shared install logic block that must stay identical across the orbs, and a checksum table keyed `"<version>/<arch>"`. Three verification modes: `false`, `known_versions`, `strict` (default, fails before downloading an unlisted version). `tests/install_test.sh` is the install contract test shared by the orbs, and `scripts/cache_key.sh` is shared too; never edit the shared parts in one orb only.

**`scripts/setup_bubblewrap.sh`**: Installs bubblewrap and, where AppArmor restricts unprivileged user namespaces (Ubuntu 23.10+), loads a profile that allows them for that `bwrap` only, through `sudo -n`. `tests/setup_bubblewrap_test.sh` stubs `sudo`, the package managers and `bwrap`.

**`scripts/lib/melange.sh`**:
- `melange_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (GitHub Actions, local runs).
- `melange_list` splits a list on commas, spaces and newlines with `read`, so an item such as `*.apk` is never globbed. `melange_flags FLAG VALUE` turns it into repeated flags with the items as they are, for package names. `melange_path_flags` does the same for flags that take paths or URLs (keyring and repository appends, pipeline dirs, env files), making items that exist locally absolute and leaving URLs alone.
- `melange_arch_args`: empty `arch` is this machine's architecture (`uname -m`, as melange names it), `all` leaves `--arch` out (every architecture the package lists), anything else is a checked comma-separated list.
- `melange_signing_key PATH ENV_VAR WORK_DIR`: without `ENV_VAR`, the key file at `PATH`; with it, the key from that variable (PEM, or base64-encoded PEM; PKCS#1 only, since melange reads nothing else) written under `umask 077` to a 0700 directory in the script's `mktemp -d` work directory, named after `PATH`'s file name (default `melange.rsa`). melange names each signature `.SIGN.RSA256.<key file name>.pub`, and apko finds the public key by that name, so the name matters. The script's EXIT trap removes it.
- `split_shell_words` and `melange_words` split `extra_args` the way container-ops-orb, oras-orb and crane-orb do: quotes keep spaces, and a `$(...)`, backtick or shell operator outside quotes fails the step.
- `melange_run` prints the command line, quoted with `printf %q`, then runs it.

**`build.sh`**: `melange build CONFIG --runner R --out-dir D [--arch A] [--signing-key K] ...`, then lists the packages in `out_dir`. `runner` defaults to `docker` (melange's own Linux default is `bubblewrap`, which fails without `setup_bubblewrap`). An empty `signing_key` builds unsigned packages, with a warning. `generate_index: false` passes `--generate-index=false`.

**`test.sh`**: `melange test CONFIG [PACKAGE] --runner R ...`. `repository_append` and `keyring_append` default to `packages` and `melange.rsa.pub`, what `build` and `keygen` write by default, so the test environment installs the built package. The optional `package` replaces the configuration's package in the main test's environment (melange's `WithTestPackage`, used in `compile.go`), such as a pinned version; subpackage tests run either way.

**`keygen.sh`**: `melange keygen --key-size N PATH` under `umask 077`, then `chmod 644` on the public key. melange's keygen replaces existing files (`os.Create`), so the script refuses when either file exists.

**`index.sh`**: one `melange index --arch A --output DIR/A/APKINDEX.tar.gz [--signing-key K] DIR/A/*.apk` per architecture directory holding APKs (or per `arch` named), for packages from several builds combined in one directory.

The scripts that handle the signing key (`build.sh`, `index.sh`) run `set +o xtrace` with a one-line comment.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT` (plus `SCRIPT_MELANGE_LIB=<lib>` for `keygen`, `build`, `test` and `index`). Inputs never appear inside a `run:` script. `install` restores and saves `actions/cache` with the command's key ingredients. `signing_key_env_var` names a variable the workflow sets in the `env` of the step that uses the action, from a secret. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. Keep the actions in sync with the command YAML by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number: every input is a string. The action descriptions leave out "Environment variables are expanded", since there is no CircleCI CLI on GitHub's runners, and say "secret" where the commands say "context". `tests/actions_test.sh` checks all of this.

### Tests

- `tests/commands_test.sh` runs `build.sh`, `test.sh`, `keygen.sh` and `index.sh` against a stand-in melange that records its arguments, working directory and the key file it was handed (name, modes, first line), and writes keygen's files. It checks every argument list, list splitting without globbing, absolute paths, `extra_args`, keys from a variable (permissions, name, removal even when melange fails), keygen's refusals, index's per-architecture calls, and each input check failing before melange runs. It runs with a circleci stand-in (value on stdin, `$ORB_TEST_VAR` expanded) and, for a few cases, with no circleci on the PATH; directories that hold a real circleci are replaced by links to everything else in them.
- `tests/smoke/melange.yaml` packages a prebuilt binary and has a `test:` block that runs it. `tests/smoke/verify.sh` checks the APK and index signatures, the index's entry and the binary.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install`, `test-setup-bubblewrap`, `test-actions`, `test-commands`, orb-tools lint, pack and review (`orb_name: melange`), shellcheck.
- `.circleci/test-deploy.yml` - `command-test` and `command-test-arm64` (install), `build-smoke-test` (amd64 and arm64 machines × docker and bubblewrap runners: keygen, build, verify, test, then index after removing the index, and verify again), `signing-key-env-var-test` (a key only in a base64-encoded variable, signatures named after `signing_key`), `setup-bubblewrap-docker-executor-test`, `env-subst-test`, `shell-conventions-test`. Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The same with the actions on GitHub's runners: `offline-tests` (actions and commands tests), `install`, `install-from-cache`, `build-smoke`, `signing-key-env-var`, and `missing-key` (a build whose key file is missing must fail).

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `melange_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, so copy `"$@"` into an array only when `$#` is non-zero. `tests/commands_test.sh` passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_MELANGE_LIB}"`). Secrets never go on a command line: a signing key reaches melange only as a file in a 0700 directory.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script.

## Naming

Command names are melange's own subcommands (`keygen`, `build`, `test`, `index`). Parameters that map onto one melange flag take its long name in snake_case (`signing_key`, `source_dir`, `out_dir`, `keyring_append`, `repository_append`, `package_append`, `pipeline_dirs`, `env_file`, `vars_file`, `namespace`, `generate_index`, `test_package_append`, `key_size`); positional arguments take melange's names for them (`config`, `package`). Plumbing matches the other juburr orbs: variables a command reads are `<thing>_env_var`, pass-through arguments are `extra_args`, and lists take commas, spaces or newlines.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh` and `yamllint .`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`
- For changes to `build`, `test` or `index`, run them with the real melange on a machine with Docker, as `build-smoke-test` does
