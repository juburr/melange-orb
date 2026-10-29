<div align="center">

<img src="assets/logos/melange-orb-512px.png" width="256" alt="Melange Orb logo: a mermaid singing into a microphone on a coral reef, beneath a container ship stacked with colorful shipping containers">

# Melange for CircleCI and GitHub Actions

### Build signed APK packages for your distroless images, right inside your CircleCI pipeline or GitHub workflow.

Install [melange](https://github.com/chainguard-dev/melange), then build, test and index signed APKs from declarative YAML pipelines, one orb command or GitHub Action each,<br>
and hand them to [apko](https://github.com/chainguard-dev/apko) to assemble minimal, distroless container images.<br>
Strict SHA-512 verification by default · Installs without `sudo` · No usage data collected

[![CircleCI Build Status](https://circleci.com/gh/juburr/melange-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/melange-orb)
[![GitHub Actions Status](https://github.com/juburr/melange-orb/actions/workflows/actions.yml/badge.svg?branch=master "GitHub Actions Status")](https://github.com/juburr/melange-orb/actions/workflows/actions.yml)
[![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/melange-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/melange-orb)
[![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)
[![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

![CircleCI orb and GitHub Actions](https://img.shields.io/badge/CI-CircleCI%20%7C%20GitHub%20Actions-F97316?style=for-the-badge)
![Builds tested with the docker and bubblewrap runners](https://img.shields.io/badge/runners-docker%20%7C%20bubblewrap-7C3AED?style=for-the-badge)
![amd64 and arm64 executors and runners](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-0EA5E9?style=for-the-badge&logo=linux&logoColor=white)
![SHA-512 verified by default](https://img.shields.io/badge/SHA--512-strict%20by%20default-16A34A?style=for-the-badge)
![melange installs without sudo](https://img.shields.io/badge/install-no%20sudo-DB2777?style=for-the-badge)

**[Quick Start](#-quick-start)** · **[Features](#-why-melange-orb)** · **[Building Packages](#-building-packages)** · **[Signing Keys](#signing-keys)** · **[CircleCI Commands](#-circleci-commands)** · **[GitHub Actions](#-github-actions)** · **[Checksums](#-checksum-verification)** · **[Security](#-secure-by-design)**

<sub>An unofficial, community-maintained CircleCI orb and set of GitHub Actions. [Contributions are welcome!](#-contributing)</sub>

</div>

<br>

## ✨ Why melange-orb?

<table>
<tr>
<td width="33%" valign="top">
🔐 <b>Verified, fail-closed installs</b><br><br>
Every melange binary comes straight from melange's official GitHub releases and is checked against a SHA-512 checksum pinned in this repository. By default, a version without a known checksum fails before anything is downloaded.
</td>
<td width="33%" valign="top">
🐙 <b>Made for apko</b><br><br>
<code>build</code> writes signed APKs and a signed <code>APKINDEX.tar.gz</code> that apko can use as a local repository, <code>test</code> runs each package's tests first, and <code>index</code> merges parallel builds. The <a href="https://github.com/juburr/apko-orb">apko orb</a> takes it from there.
</td>
<td width="33%" valign="top">
🧪 <b>Tested end to end</b><br><br>
Every change builds, tests, indexes and verifies a signed APK on amd64 and arm64, with both the <code>docker</code> and <code>bubblewrap</code> runners, on CircleCI and on GitHub's runners. See <a href="#choosing-a-runner">Choosing a Runner</a>.
</td>
</tr>
<tr>
<td width="33%" valign="top">
🦾 <b>amd64 and arm64</b><br><br>
The matching Linux build is picked automatically, including on CircleCI's <code>arm.medium</code> machines and GitHub's <code>ubuntu-24.04-arm</code> runners, and cached per version and architecture so repeat jobs skip the download. Cached copies are verified too.
</td>
<td width="33%" valign="top">
📌 <b>200+ releases covered</b><br><br>
Checksums for melange releases from <code>0.1.0</code> up to the pinned default, on both architectures. Pick yours with <code>version</code>.
</td>
<td width="33%" valign="top">
🔑 <b>Keys that stay secret</b><br><br>
Sign with a per-job key from <code>keygen</code>, or a lasting one from a context or secret, written to a private file for the step and removed after. melange installs without root, and no usage data is collected.
</td>
</tr>
</table>

## 🔄 How It Works

```mermaid
flowchart LR
    gh["GitHub release"] --> sha{"SHA-512<br/>verified?"}
    sha -- yes --> bin["melange<br/>on PATH"]
    sha -- no --> stop["install fails"]
    bin --> keygen["keygen"]
    yaml["melange.yaml"] --> build["build<br/>runner: docker"]
    keygen --> build
    build --> apks["Signed APKs and<br/>APKINDEX in packages/"]
    apks --> test["test"]
    test --> apko["Local repository<br/>for apko"]

    classDef install fill:#0EA5E9,stroke:#0369A1,color:#FFFFFF
    classDef tool fill:#7C3AED,stroke:#4C1D95,color:#FFFFFF
    classDef good fill:#16A34A,stroke:#14532D,color:#FFFFFF
    classDef bad fill:#DC2626,stroke:#7F1D1D,color:#FFFFFF
    class gh,sha,bin install
    class keygen,yaml,build,test tool
    class apks,apko good
    class stop bad
```

`melange/install`, or the `install` action on GitHub, downloads melange straight from its official GitHub releases, verifies its SHA-512 checksum in the default `strict` mode shown here, and puts it on `PATH`. See [Checksum Verification](#-checksum-verification) for the other modes. Then `keygen` creates a signing key pair, `build` runs your package's pipeline in an isolated build environment and writes signed APKs and a signed `APKINDEX.tar.gz` to `packages/<arch>/`, and `test` runs the package's tests against them, ready for apko to install from. Each command runs the `melange` CLI, which stays on the `PATH` for anything the commands don't cover.

## 🚀 Quick Start

Install melange, generate a signing key, then build and test your packages, one step each. In either example, swap in your own `melange.yaml` and the directory your package's sources or prebuilt files live in (`source_dir`). `packages/<arch>/` then holds your signed APKs and a signed `APKINDEX.tar.gz`, and `melange.rsa.pub` is the key apko trusts them by. See [Building Packages](#-building-packages) for what each step does and how to pick a runner.

### CircleCI

Add the orb and call its commands:

```yaml
version: 2.1

orbs:
  melange: juburr/melange-orb@1.3.1

jobs:
  build-apks:
    machine:
      image: ubuntu-2404:current
    resource_class: arm.medium # or medium for amd64
    steps:
      - checkout
      - melange/install
      - melange/keygen # writes melange.rsa and melange.rsa.pub
      - melange/build:
          config: melange.yaml
          source_dir: dist
      - melange/test:
          config: melange.yaml

workflows:
  build:
    jobs:
      - build-apks
```

> [!NOTE]
> Run `build` and `test` on a machine executor, as above. Neither runner works on the Docker executor: see [Why Not the Docker Executor?](#why-not-the-docker-executor)

> [!TIP]
> Upgrading the orb from 0.1.0? `install` now refuses melange versions it has no checksum for, and creates `install_path` and puts it on the `PATH` for you. See [Upgrading](#-upgrading).

### GitHub Actions

Use the actions:

```yaml
name: Build APKs

on: push

jobs:
  build-apks:
    runs-on: ubuntu-24.04-arm # or ubuntu-24.04 for amd64
    steps:
      - uses: actions/checkout@v7
      - uses: juburr/melange-orb/actions/install@v1.3.1
      - uses: juburr/melange-orb/actions/keygen@v1.3.1 # writes melange.rsa and melange.rsa.pub
      - uses: juburr/melange-orb/actions/build@v1.3.1
        with:
          config: melange.yaml
          source_dir: dist
      - uses: juburr/melange-orb/actions/test@v1.3.1
        with:
          config: melange.yaml
```

See [GitHub Actions](#-github-actions) for how the actions map to the orb's commands.

## 🏭 Building Packages

The [Quick Start](#-quick-start) jobs are the same flow CI runs on every change, on amd64 and arm64: on CircleCI's machine executors (`build-smoke-test` in [`.circleci/test-deploy.yml`](.circleci/test-deploy.yml)) and on GitHub's runners (`build-smoke` in [`.github/workflows/actions.yml`](.github/workflows/actions.yml)). It generates a signing key, builds a package that copies a prebuilt binary into a signed APK for the machine's own architecture, runs the package's tests, and writes its index again with `index`.

- `build` and `test` work on the machine's own architecture unless `arch` names others (`x86_64,aarch64`) or is `all`, every architecture the package lists. Building for a foreign architecture needs emulation.
- Packages are written to `packages/<arch>/` (`x86_64` or `aarch64`) along with an `APKINDEX.tar.gz` signed by `melange.rsa`. apko can then use the directory as a local repository, with `melange.rsa.pub` as the trusted key.
- `source_dir` is the directory the build workspace starts with, such as prebuilt binaries to package. It defaults to the configuration file's directory, as in melange.
- `keyring_append`, `repository_append` and `package_append` add keys, repositories and packages to the build environment, for example the `packages` directory of an earlier build that this package depends on. Local paths in the key and repository lists are made absolute; package names are passed as they are.
- `extra_args` takes any other `melange build` flag, such as `--timeout 30m`. It is split like shell words, and nothing in it runs as shell code.

Next, assemble an image: the companion [apko orb](https://github.com/juburr/apko-orb) installs apko with the same checksum verification, and its [local signed repository guide](https://github.com/juburr/apko-orb#-installing-packages-from-a-local-signed-repository) shows how to list `packages` and `melange.rsa.pub` in the apko configuration.

### Testing Packages

`test` runs the configuration's `test:` pipelines with `melange test`, in a fresh environment built from the test's own `environment`. It installs the package under test from `repository_append` (default `packages`) and trusts `keyring_append` (default `melange.rsa.pub`), the defaults of `build` and `keygen`. Subpackages with tests are tested too. A failing test fails the step, so the packages never reach apko.

```yaml
test:
  environment:
    contents:
      keyring:
        - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub
      repositories:
        - https://packages.wolfi.dev/os
      packages:
        - busybox
  pipeline:
    - runs: my-app --version
```

### Signing Keys

`keygen` writes a key pair per job: `melange.rsa`, readable only by the job's user, and `melange.rsa.pub`. It never replaces a key that is already there. That suits packages that apko installs in the same pipeline.

For packages you publish, keep one lasting key in a context (or a GitHub secret), and pass the name of the variable that holds it as `signing_key_env_var`, with the key as PEM or base64-encoded PEM. `build` and `index` write it to a file only the job's user can read, named after `signing_key`'s file name, and remove it when the step ends, so it never sits in the workspace. melange names each signature after that file name, so apko must trust a public key of the same name:

```yaml
- melange/build:
    config: melange.yaml
    signing_key: my-org.rsa # signatures name my-org.rsa.pub
    signing_key_env_var: MELANGE_SIGNING_KEY
```

On GitHub, set the variable in the `env` of the step, from a secret:

```yaml
- uses: juburr/melange-orb/actions/build@v1.3.1
  env:
    MELANGE_SIGNING_KEY: ${{ secrets.MELANGE_SIGNING_KEY }}
  with:
    config: melange.yaml
    signing_key: my-org.rsa
    signing_key_env_var: MELANGE_SIGNING_KEY
```

The key must be an RSA key in PKCS#1 PEM (`-----BEGIN RSA PRIVATE KEY-----`), as `melange keygen` writes. Convert a PKCS#8 key with `openssl rsa -traditional -in key.pem -out my-org.rsa`.

### Combining Parallel Builds

`build` indexes the packages it writes, so when several jobs each build some of the packages and a workspace (or downloaded artifacts) combines their `packages` directories, each index lists only one job's packages. Run `index` on the combined directory: it writes a fresh, signed `APKINDEX.tar.gz` for each architecture, listing every APK in it. The [`signing_key_from_context`](src/examples/signing_key_from_context.yml) example builds two packages in parallel jobs and indexes them together.

### Choosing a Runner

`melange build` runs each package's pipeline in an isolated build environment created by a *runner*. Results on CircleCI's `ubuntu-2404:current` machine images (amd64 `medium` and arm64 `arm.medium`):

| Runner | Result | Setup |
| --- | --- | --- |
| `docker` (recommended) | ✅ Works on amd64 and arm64 | None. The `circleci` user can already use the machine's Docker daemon. No images are pulled; melange builds the build environment locally. |
| `bubblewrap` (melange's default on Linux) | ✅ Works on amd64 and arm64 after `melange/setup_bubblewrap` | Add [`melange/setup_bubblewrap`](#melangesetup_bubblewrap), which uses `sudo`. It installs `bubblewrap` and allows it to create user namespaces, which Ubuntu 24.04's AppArmor restricts (`kernel.apparmor_restrict_unprivileged_userns = 1`). Without that, the build fails with `bwrap: setting up uid map: Permission denied`. |
| `qemu` | ❌ Not usable | Needs `/dev/kvm`, which machine executors don't provide. |

`build` and `test` use the `docker` runner unless `runner` says otherwise. (melange's own default on Linux is `bubblewrap`, which fails unless `setup_bubblewrap` has run.)

The `docker` runner needs no setup and no `sudo`, so it is the simpler choice on CircleCI. Use `bubblewrap` when the machine has no Docker daemon, such as a self-hosted machine runner without Docker, or to build the way melange does by default. Add `setup_bubblewrap` after `install` and set `runner: bubblewrap`:

```yaml
steps:
  - checkout
  - melange/install
  - melange/setup_bubblewrap
  - melange/keygen
  - melange/build:
      config: melange.yaml
      runner: bubblewrap
      source_dir: dist
  - melange/test:
      config: melange.yaml
      runner: bubblewrap
```

### Why Not the Docker Executor?

Neither runner can build on the Docker executor, so `build` and `test` need a machine executor:

- **`docker` runner**: melange bind-mounts its build workspace, a directory under `/tmp` in the job's container, into the container it builds in. The Docker executor has no Docker daemon of its own, and `setup_remote_docker` starts one on a separate VM that can't see the job's files. The build fails with `invalid mount config for type "bind": bind source path does not exist: /tmp/melange-workspace-…`.
- **`bubblewrap` runner**: the job runs in an unprivileged container, where `bwrap` can't set up its sandbox. On CircleCI's Docker executor it stops with `Unexpected capabilities but not setuid, old file caps config?`, and under Docker's default security settings it can't create the namespaces it needs either, even as root. `setup_bubblewrap` fails there with an error that says so, and CI checks that it does (`setup-bubblewrap-docker-executor-test` in [`.circleci/test-deploy.yml`](.circleci/test-deploy.yml)).

## 🧰 CircleCI Commands

### `melange/install`

Installs melange for Linux on amd64 or arm64, matching the executor's CPU. In the default `strict` mode it verifies the SHA-512 checksum first and refuses versions it has no checksum for; see [Checksum Verification](#-checksum-verification) for the opt-outs. Run it before any `melange` step. Needs bash 4 or newer on the executor.

| Parameter | Default | Description |
| --- | --- | --- |
| `version` | `0.63.1` | melange release to install; a leading `v` is ignored. Pin it so melange only changes when you decide to. Values that aren't a release version, such as `latest`, are rejected. |
| `install_path` | `$HOME/bin` | Absolute path of the directory to install the `melange` binary into, writable without root. Created if needed, and added to `PATH` for later steps when it isn't already on it. A leading `~/` is expanded. |
| `verify_checksums` | `strict` | `strict`, `known_versions` or `false`. See [Checksum Verification](#-checksum-verification). |
| `caching` | `true` | Cache the downloaded release tarball between jobs, keyed by melange version, CPU architecture and home directory. Only verified tarballs are cached, and they are verified again when restored. |

Environment variables are expanded in `version` and `install_path`.

### `melange/setup_bubblewrap`

Prepares a Linux machine executor for `melange build --runner bubblewrap`. It takes no parameters, and changes nothing when `bwrap` already works:

1. Installs `bubblewrap` with the system package manager (`apt-get`, `dnf`, `yum`, `zypper` or `apk`) if `bwrap` isn't on the `PATH`.
2. If `bwrap` can't create a user namespace because AppArmor restricts unprivileged ones, as on Ubuntu 23.10 and newer, loads an AppArmor profile that allows them for that `bwrap` alone. It is named after the binary's path, such as `melange-orb-bwrap-userns/usr/bin/bwrap`. The rest of the system keeps the restriction. The profile is loaded until the machine reboots, and nothing is written to `/etc/apparmor.d`. This is the fix from [melange#1508](https://github.com/chainguard-dev/melange/issues/1508). No profile is loaded when something else is known to stop `bwrap`: user namespaces turned off (`user.max_user_namespaces` or `kernel.unprivileged_userns_clone` is `0`), or a `bwrap` too old for melange.
3. Checks, as the job's user, that `bwrap` can create the namespaces and the `/proc` mount melange's runner uses, and fails with an explanation if it can't.

Installing a package and loading a profile need root. The command runs them directly as root, or through `sudo -n` otherwise, which never prompts for a password. CircleCI's machine executors allow passwordless `sudo`. The Docker executor can't run bubblewrap at all, so the command fails there (see [Why Not the Docker Executor?](#why-not-the-docker-executor)). On a system with another package manager, install `bubblewrap` in an earlier step and the command does the rest.

### `melange/keygen`

Generates an RSA key pair with `melange keygen`: the private key at `signing_key`, readable only by the job's user, and the public key next to it with `.pub` appended. Fails rather than replace a key that is already there, since `melange keygen` itself would. See [Signing Keys](#signing-keys).

| Parameter | Default | Description |
| --- | --- | --- |
| `signing_key` | `melange.rsa` | Path of the private key to write. Missing directories are created. |
| `key_size` | `4096` | Size of the RSA key, in bits. |

### `melange/build`

Builds APK packages with `melange build`, signed with `signing_key`, into `out_dir/<arch>/` with a signed `APKINDEX.tar.gz`. Needs a machine executor; the `bubblewrap` runner also needs [`setup_bubblewrap`](#melangesetup_bubblewrap).

| Parameter | Default | Description |
| --- | --- | --- |
| `config` | `melange.yaml` | Path of the melange configuration to build. |
| `arch` | *(empty)* | Architectures to build, separated by commas. Empty is the machine's own; `all` is every architecture the package lists. |
| `runner` | `docker` | `docker`, `bubblewrap` or `qemu`. See [Choosing a Runner](#choosing-a-runner). |
| `signing_key` | `melange.rsa` | Private key to sign with. Empty builds unsigned packages, which apko refuses unless it ignores signatures. |
| `signing_key_env_var` | *(empty)* | Name of a variable holding the private key, as PEM or base64-encoded PEM. See [Signing Keys](#signing-keys). |
| `source_dir` | *(empty)* | Directory the build workspace starts with. Empty is the configuration file's directory. |
| `out_dir` | `packages` | Directory to write the packages to, a subdirectory per architecture. |
| `keyring_append` | *(empty)* | More public keys for the build environment. |
| `repository_append` | *(empty)* | More repositories for the build environment, such as an earlier build's `packages`. |
| `package_append` | *(empty)* | More packages to install in the build environment. |
| `pipeline_dirs` | *(empty)* | Directories of your own pipelines for `uses:` steps. |
| `env_file` | *(empty)* | Files of environment variables to preload in the build environment. |
| `vars_file` | *(empty)* | File of variables for the configuration's `vars:` block. |
| `namespace` | *(empty)* | Namespace for the package URLs in the packages' SBOMs. Empty is melange's default, `unknown`. |
| `generate_index` | `true` | Write a signed `APKINDEX.tar.gz` per architecture. |
| `extra_args` | *(empty)* | More `melange build` arguments, split like shell words, such as `--timeout 30m`. Nothing in them runs as shell code. |

Lists take commas, spaces or newlines. Local paths in the lists of keys, repositories, pipeline directories and env files are made absolute; package names are passed as they are.

### `melange/test`

Runs the configuration's `test:` pipelines with `melange test`, installing the package from `repository_append`. Needs a machine executor, as `build` does. See [Testing Packages](#testing-packages).

| Parameter | Default | Description |
| --- | --- | --- |
| `config` | `melange.yaml` | Path of the melange configuration whose tests to run. |
| `package` | *(empty)* | Package for the main test to install instead of the configuration's, such as `hello=1.2.3-r0`. |
| `arch` | *(empty)* | Architectures to test, as for `build`. |
| `runner` | `docker` | `docker`, `bubblewrap` or `qemu`. |
| `repository_append` | `packages` | Repositories to install the package under test from. |
| `keyring_append` | `melange.rsa.pub` | Public keys to trust for those repositories. |
| `test_package_append` | *(empty)* | More packages to install in the test environment. |
| `source_dir` | *(empty)* | Directory the test workspace starts with. Empty is the configuration file's directory. |
| `pipeline_dirs` | *(empty)* | Directories of your own pipelines for `uses:` steps. |
| `env_file` | *(empty)* | Files of environment variables to preload in the test environment. |
| `extra_args` | *(empty)* | More `melange test` arguments, split like shell words. |

### `melange/index`

Writes a fresh, signed `APKINDEX.tar.gz` for each architecture directory under `packages_dir` with `melange index`, listing every APK in it. See [Combining Parallel Builds](#combining-parallel-builds).

| Parameter | Default | Description |
| --- | --- | --- |
| `packages_dir` | `packages` | Directory with a subdirectory of APKs per architecture. |
| `arch` | *(empty)* | Architectures to index, separated by commas. Empty is every directory that has APKs. |
| `signing_key` | `melange.rsa` | Private key to sign with, as for `build`. Empty writes unsigned indexes. |
| `signing_key_env_var` | *(empty)* | Name of a variable holding the private key, as for `build`. |

Environment variables are expanded in the string parameters of `keygen`, `build`, `test` and `index`. `runner` is an enum, and `generate_index` and `key_size` are a boolean and an integer, which CircleCI checks before any step runs.

## ⚡ GitHub Actions

Each of the orb's commands has a GitHub Action of the same name. The actions run the same scripts as the orb, so they install and verify melange the same way, and take the same inputs with the same defaults.

| Action | Orb command | Inputs |
| --- | --- | --- |
| `juburr/melange-orb/actions/install` | [`melange/install`](#melangeinstall) | `version`, `install_path`, `verify_checksums`, `caching` |
| `juburr/melange-orb/actions/setup_bubblewrap` | [`melange/setup_bubblewrap`](#melangesetup_bubblewrap) | None |
| `juburr/melange-orb/actions/keygen` | [`melange/keygen`](#melangekeygen) | `signing_key`, `key_size` |
| `juburr/melange-orb/actions/build` | [`melange/build`](#melangebuild) | `config`, `arch`, `runner`, `signing_key`, `signing_key_env_var`, `source_dir`, `out_dir`, and the rest of `build`'s parameters |
| `juburr/melange-orb/actions/test` | [`melange/test`](#melangetest) | `config`, `package`, `arch`, `runner`, `repository_append`, `keyring_append`, and the rest of `test`'s parameters |
| `juburr/melange-orb/actions/index` | [`melange/index`](#melangeindex) | `packages_dir`, `arch`, `signing_key`, `signing_key_env_var` |

The [Quick Start](#github-actions) shows a complete workflow. To build with the bubblewrap runner instead of docker, add the setup step after the install and set `runner: bubblewrap`:

```yaml
      - uses: juburr/melange-orb/actions/install@v1.3.1
      - uses: juburr/melange-orb/actions/setup_bubblewrap@v1.3.1
      - uses: juburr/melange-orb/actions/keygen@v1.3.1
      - uses: juburr/melange-orb/actions/build@v1.3.1
        with:
          config: melange.yaml
          runner: bubblewrap
```

How they differ from the orb's commands:

- **Versions.** An action is referenced by the repository's release tag, such as `v1.3.1`, the same tag the orb is published from. There is no moving major tag such as `v1` yet. For the strongest pinning, use the tag's commit SHA: `juburr/melange-orb/actions/install@<sha> # v1.3.1`.
- **Environment variables.** The orb expands `$NAME` in string parameters with the CircleCI CLI, which GitHub's runners don't have, so the actions take values as they are. Use GitHub's expressions instead, such as `version: ${{ vars.MELANGE_VERSION }}`. A leading `~` in `install_path` is still the home directory.
- **Signing keys.** `signing_key_env_var` names a variable that the step using `build` or `index` sets in its `env`, from a secret, as [Signing Keys](#signing-keys) shows. The key never passes through an input.
- **Caching.** `caching` stores the verified release with [`actions/cache`](https://github.com/actions/cache), with the same key ingredients as the orb (melange version, CPU architecture, home directory). The cache is restored before the install and saved right after it, and the release is verified again when restored. It counts toward the repository's GitHub Actions cache storage.
- **`PATH`.** `install` puts `install_path` on the `PATH` of later steps through `GITHUB_PATH`.
- **Runners.** GitHub-hosted Linux runners are full virtual machines with Docker and passwordless `sudo`, so both melange runners work there. CI builds and verifies a signed APK with each of them on `ubuntu-24.04` and `ubuntu-24.04-arm`. A self-hosted runner that runs jobs in an unprivileged container has the [same limits](#why-not-the-docker-executor) as CircleCI's Docker executor.

The actions are composite actions in [`actions/`](actions), next to the orb's source. Each passes its inputs to the orb's script as environment variables, and [`actions/run_script.sh`](actions/run_script.sh) gives the script what CircleCI would: a `BASH_ENV` file for the values it hands to later steps, which it then passes on through `GITHUB_PATH` and `GITHUB_ENV`.

## 📦 Upgrading

Upgrading from v1.3.0 to v1.3.1? Nothing changes for pipelines or workflows. v1.3.1 fixes [`setup_bubblewrap`](#melangesetup_bubblewrap) on executors whose bash is older than 4.3, such as CentOS 7 and Amazon Linux 2: it read every kernel setting from the wrong path, so it never loaded the AppArmor profile where AppArmor restricts user namespaces, and a failure didn't say that `user.max_user_namespaces` or `kernel.unprivileged_userns_clone` turns them off.

Upgrading from v1.2.2 to v1.3.0? Nothing changes for existing pipelines or workflows. v1.3.0 adds the [`keygen`](#melangekeygen), [`build`](#melangebuild), [`test`](#melangetest) and [`index`](#melangeindex) commands and their GitHub Actions, which run the `melange` steps the examples used to spell out by hand. Steps that run `melange` directly keep working.

Upgrading from v1.2.1 to v1.2.2? Nothing changes for CircleCI pipelines. Two fixes to the GitHub Actions: they no longer trace the step's environment in a job that traces every step (`SHELLOPTS=xtrace`, or `set -x` in its `BASH_ENV`), where a secret could reach the log in a form GitHub doesn't mask; and they pass on every variable a command exports, even one the step already had.

Upgrading from v1.2.0 to v1.2.1? Nothing changes for pipelines or workflows. The GitHub Actions' `actions/run_script.sh` is now the copy every juburr orb with actions shares, which also takes optional library files that melange's actions don't use.

Upgrading from v1.1.0 to v1.2.0? The default `version` is now melange 0.63.1 (it was 0.61.2), and the checksum table covers every release up to it. Set `version: 0.61.2` to stay on the old default. Nothing else changes for CircleCI pipelines: v1.2.0 also adds [GitHub Actions](#-github-actions) for both commands.

Upgrading from v1.0.0 to v1.1.0? Nothing changes for existing pipelines. v1.1.0 adds the [`setup_bubblewrap`](#melangesetup_bubblewrap) command.

Upgrading from 0.1.0 to v1.0.0? No parameters were renamed, but `install` changed.

Behavior changes:
- `verify_checksums` defaults to `strict` instead of `known_versions`, so a melange version with no checksum in the orb's table fails the install. See [Checksum Verification](#-checksum-verification).
- `install_path` defaults to `$HOME/bin` instead of `/home/circleci/bin`, the same directory on CircleCI's images. It must be an absolute path without a `:`, and `install` creates it and adds it to the `PATH` of later steps when needed, so you no longer have to prepare it in an earlier step.
- `version` must be a release version, such as `0.61.2`. Anything else is rejected before anything is downloaded.
- `install` needs bash 4 or newer, and fails when the downloaded binary can't run on the executor.
- The cache key and location changed, so the first run after upgrading downloads melange again.

## 🔒 Secure by Design

- **Least Privilege**: `install` puts melange in a user-owned directory and never uses `sudo`. Only `setup_bubblewrap`, which you add for the bubblewrap runner, runs commands as root: the package manager, and `apparmor_parser` to allow user namespaces for `bwrap` alone instead of lifting the restriction for every program.
- **Integrity**: SHA-512 checksum validation of downloaded binaries, on by default and failing closed: a melange version this orb has no checksum for is refused, not installed unverified, and a binary that can't run on the executor never replaces an existing install. See [Checksum Verification](#-checksum-verification) for the `known_versions` and `false` opt-outs.
- **Provenance**: Installs directly from melange's official [releases page](https://github.com/chainguard-dev/melange/releases/) on GitHub. No third-party websites, domains, or proxies are used. `setup_bubblewrap` installs bubblewrap from the package repositories the executor is already configured with.
- **Signing keys**: `keygen` leaves the private key readable by the job's user only, and never replaces an existing key. A key from `signing_key_env_var` is written to a private directory for the one step that needs it and removed when the step ends, even when it fails; those steps never trace commands.
- **Confidentiality**: All secrets and environment variables are handled in accordance with CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) and [best practices](https://circleci.com/docs/orbs-best-practices/). The GitHub Actions pass inputs to the scripts as environment variables, never pasting them into a script, and pin the actions they use (`actions/cache`) to a commit SHA.
- **Privacy**: No usage data of any kind is collected or shipped back to the orb developer.

> [!IMPORTANT]
> **Info for security teams:** see [Network Access](#-network-access) for the hosts to allow on locked-down or self-hosted runners.

## 💻 Supported Platforms

Linux executors on `x86_64` (amd64) and `aarch64`/`arm64` (arm64), including CircleCI [Arm resource classes](https://circleci.com/docs/using-arm/) such as `arm.medium`. The `install` command picks the melange release asset for the architecture reported by `uname -m` and, in the default `strict` mode, verifies it against that architecture's SHA-512 checksum. Any other operating system or architecture fails the install rather than installing a binary that can't run.

| `uname -m` | Release asset installed |
| --- | --- |
| `x86_64` or `amd64` | `melange_<version>_linux_amd64.tar.gz` |
| `aarch64` or `arm64` | `melange_<version>_linux_arm64.tar.gz` |

`install` needs bash 4 or newer, `curl` or `wget`, `awk`, `tar`, `gzip`, and the standard coreutils, including `mktemp` and, when it verifies, `sha512sum`. CI runs it on the Docker executor (`cimg/base`) and on amd64 and arm64 machine executors (`ubuntu-2404:current`); for `melange build` itself, use a machine executor (see [Choosing a Runner](#choosing-a-runner)).

The download cache is keyed by melange version, executor architecture and home directory, so amd64 and arm64 jobs in the same project never restore each other's downloads. On executors whose `PATH` doesn't already include `install_path` (for example, machine executors), `install` adds it for later steps through `BASH_ENV`.

The [GitHub Actions](#-github-actions) run on GitHub-hosted `ubuntu-24.04` (amd64) and `ubuntu-24.04-arm` (arm64) runners, which CI covers, and on self-hosted Linux runners with the same tools.

## 🔐 Checksum Verification

The `install` command checks the downloaded `melange` binary against a SHA-512 lookup table built into the orb ([`src/scripts/install.sh`](src/scripts/install.sh)), with one entry per melange version and architecture. With the default `verify_checksums: strict`, an install goes like this:

```mermaid
flowchart LR
    start(["melange/install"]) --> known{"Checksum listed<br/>for version + arch?"}
    known -- "no" --> refuse["❌ Fail before<br/>downloading"]
    known -- "yes" --> cached{"Tarball in<br/>CircleCI cache?"}
    cached -- "no" --> download["⬇️ Download from<br/>melange's GitHub releases"]
    cached -- "yes" --> vcache{"SHA-512<br/>matches?"}
    vcache -- "no: discard it" --> download
    download --> verify{"SHA-512<br/>matches?"}
    verify -- "no" --> mismatch["❌ Fail"]
    verify -- "yes" --> installed["✅ Install to<br/>install_path"]
    vcache -- "yes" --> installed

    classDef install fill:#0EA5E9,stroke:#0369A1,color:#FFFFFF
    classDef good fill:#16A34A,stroke:#14532D,color:#FFFFFF
    classDef bad fill:#DC2626,stroke:#7F1D1D,color:#FFFFFF
    class start,known,cached,vcache,download,verify install
    class installed good
    class refuse,mismatch bad
```

The `verify_checksums` parameter controls what happens:

| Value | Version in the orb's table | Version not in the table |
| --- | --- | --- |
| `strict` (default) | ✅ Verified; install fails on mismatch | ⛔ Install fails before melange is downloaded from GitHub or a cached copy is unpacked |
| `known_versions` | ✅ Verified; install fails on mismatch | ⚠️ Installed **unverified**, with a warning |
| `false` | ⚠️ Not verified, with a warning | ⚠️ Installed **unverified**, with a warning |

The table covers melange releases from 0.1.0 up to the default `version`, on both architectures. If you pin a melange release newer than this orb, `strict` fails until the orb is upgraded. Upgrade the orb (or open a PR adding the checksum, see [Contributing](#-contributing)) rather than opting out. To accept an unverified binary in the meantime, opt out explicitly:

```yaml
steps:
  - melange/install:
      version: "0.62.0"
      verify_checksums: known_versions
```

> [!WARNING]
> Before v1.0.0 the default was `known_versions`, which installed unlisted versions without verification. Pipelines that pin a `version` this orb does not list now fail until the orb is upgraded.

## 🌐 Network Access

Hosts to allow (HTTPS, port 443) when running on a locked-down or self-hosted runner:

| Host | Needed by | Purpose |
| --- | --- | --- |
| `github.com` | `install` | melange release download |
| `release-assets.githubusercontent.com` | `install` | Where GitHub redirects release downloads. The download fails if it is blocked. |
| `objects.githubusercontent.com` | `install` | GitHub's previous redirect target for release downloads; allow it as well so a change on GitHub's side doesn't break downloads |

`build` and `test` (`melange build` and `melange test`) need more when building against the [Wolfi](https://wolfi.dev) package repository:

| Host | Needed by | Purpose |
| --- | --- | --- |
| `packages.wolfi.dev` | `build`, `test` | Serves the repository's signing key (`/os/wolfi-signing.rsa.pub`), package index, and the packages that make up the build environment, such as `busybox` |
| Other repository, keyring and source hosts | `build`, `test` | Builds that list other repositories or keyrings in `environment.contents`, fetch sources (`fetch`, `git-checkout`), or download anything from pipeline steps (for example `go mod download`, `npm install`, or `pip install` with a cold cache) also need the hosts those steps contact |

The `docker` runner pulls no container images, since melange builds the build environment locally, so it needs no registry access.

With `caching`, the GitHub `install` action also reaches GitHub's cache service through `actions/cache`. GitHub-hosted runners always can; a self-hosted runner needs the hosts GitHub lists for [communication with GitHub](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#communication-between-self-hosted-runners-and-github).

`setup_bubblewrap` downloads nothing itself. When `bubblewrap` isn't installed, the package manager fetches it from the repositories the machine is configured with. On Ubuntu those are its archive mirrors, by default `archive.ubuntu.com` and `security.ubuntu.com` (`ports.ubuntu.com` on arm64), usually over HTTP on port 80. `apt-get update` also contacts every other repository in the machine's sources, but the install carries on if those fail.

## 🤝 Contributing

This is an unofficial, community-maintained orb, and contributions are welcome! Bug reports, feature ideas and pull requests all help.

- **Found a bug or have an idea?** [Open an issue](https://github.com/juburr/melange-orb/issues).
- **Need a newer melange release?** Generate its checksums with `src/scripts/install_hash.sh -v <version>`, paste them into the `sha512sums` table in [`src/scripts/install.sh`](src/scripts/install.sh), and open a pull request. The script downloads the amd64 and arm64 tarballs, checks them against the SHA-256 checksums melange publishes with the release (`checksums.txt`), and prints one lookup table entry per architecture. It needs bash 4 or newer, `curl`, `awk`, `sed`, `tar`, `gzip` and the standard coreutils, including `mktemp`, `sha256sum` and `sha512sum`. For a release with nothing published to check against, `-c` takes a checksum from another official source (a SHA-1 one also needs `sha1sum`), or `NONE`; it never overrides what the release did publish.
- **Before opening a pull request**, run `yamllint .`, `shellcheck src/scripts/*.sh src/scripts/lib/*.sh actions/*.sh tests/*.sh`, `bash tests/install_test.sh`, `bash tests/setup_bubblewrap_test.sh`, `bash tests/commands_test.sh`, `bash tests/actions_test.sh`, `bash tests/env_subst_test.sh` and `bash tests/shell_conventions_test.sh`. The install tests stub out the network, the setup_bubblewrap tests stub out `sudo`, the package managers and `bwrap`, and the commands tests stub out `melange`, so they run anywhere without changing the machine.

CI lints and packs the orb, runs ShellCheck, and runs the install and build smoke tests (keygen, build, test and index, with each runner) on amd64 and arm64 before any release is published. A GitHub workflow ([`.github/workflows/actions.yml`](.github/workflows/actions.yml)) runs the same tests with the GitHub Actions on GitHub's own runners. `tests/actions_test.sh` keeps each action in step with its command: the same inputs and defaults, passed to the same scripts.

## 🎨 Logo

Need the logo for a slide deck, blog post, or internal developer portal? PNGs with transparent backgrounds are in [`assets/logos`](assets/logos): [64](assets/logos/melange-orb-64px.png) · [128](assets/logos/melange-orb-128px.png) · [256](assets/logos/melange-orb-256px.png) · [512](assets/logos/melange-orb-512px.png) · [1024](assets/logos/melange-orb-1024px.png) px

## 📜 License

[MIT](LICENSE) © 2024-2026 Justin Burr

<br>

<div align="center">
  <img src="assets/logos/melange-orb-128px.png" width="64" alt="Melange Orb logo">
  <br>
  <sub>Signed APKs, built in CI. If this orb helps your team, a ⭐ helps others find it.</sub>
  <br>
  <sub><a href="#melange-for-circleci-and-github-actions">Back to top ↑</a></sub>
</div>
