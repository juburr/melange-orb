<div align="center">
  <img align="center" width="320" src="assets/logos/melange-orb-logo.png" alt="Melange Orb">
  <h1>CircleCI Melange Orb</h1>
  <i>An orb for simplifying Melange installation and use within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/melange-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/melange-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/melange-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/melange-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/melange-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an unofficial Melange orb used for installing Melange in your CircleCI pipeline to build packages for distroless container images. Contributions are welcome!

## Features
### **Secure By Design**
- **Least Privilege**: Installs to a user-owned directory by default, with no `sudo` usage anywhere in this orb.
- **Integrity**: Checksum validation of all downloaded binaries using SHA-512. Installs fail closed by default when no checksum is known for the requested version (see [Checksum Verification](#checksum-verification)).
- **Provenance**: Installs directly from Melange's official [releases page](https://github.com/chainguard-dev/melange/releases/) on GitHub. No third-party websites, domains, or proxies are used.
- **Confidentiality**: All secrets and environment variables are handled in accordance with CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) and [best practices](https://circleci.com/docs/orbs-best-practices/).
- **Privacy**: No usage data of any kind is collected or shipped back to the orb developer.

Info for security teams:
- Required external access to allow, if running a locked down, self-hosted CircleCI pipeline on-prem:
  - `github.com`: For download and installation of the Melange tool.

## Checksum Verification

The `install` command checks the SHA-512 checksum of the downloaded `melange` binary against a table of checksums maintained in this orb ([`src/scripts/install.sh`](src/scripts/install.sh)). The `verify_checksums` parameter controls what happens:

| `verify_checksums` | Version listed in this orb | Version not listed in this orb |
|---|---|---|
| `strict` (default) | Verified; the install fails on a mismatch | The install fails before melange is downloaded from GitHub or a cached copy is unpacked |
| `known_versions` | Verified; the install fails on a mismatch | Installed **without** verification (a warning is logged) |
| `false` | Not verified (a warning is logged) | Not verified (a warning is logged) |

> [!IMPORTANT]
> Before v0.2.0 the default was `known_versions`, which installed unlisted versions without verification. Pipelines that pin a `version` this orb does not list now fail until the orb is upgraded.

If you need a melange release that this orb doesn't list yet, upgrade the orb or open a PR that adds its checksum (generated with [`src/scripts/install_hash.sh`](src/scripts/install_hash.sh)). To accept an unverified binary in the meantime, opt out explicitly:

```yaml
steps:
  - melange/install:
      version: "0.62.0"
      verify_checksums: known_versions
```

## Supported Platforms

The `install` command detects the machine architecture with `uname -m` and installs the matching Linux build of melange:

| `uname -m` | Release asset installed |
|---|---|
| `x86_64` | `melange_<version>_linux_amd64.tar.gz` |
| `aarch64` or `arm64` | `melange_<version>_linux_arm64.tar.gz` |

Any other architecture, or an operating system other than Linux, fails the install. Checksums are recorded per version and architecture, so `strict` verification covers both amd64 and arm64 (for example, CircleCI's `arm.medium` resource class). The cache key also includes the architecture, so amd64 and arm64 jobs in the same project never restore each other's downloads.

## Building Packages

This orb only installs melange. Call the `melange` CLI directly in later steps. On every change, the orb's own CI runs the workflow below on amd64 and arm64 machine executors (see `build-smoke-test` in [`.circleci/test-deploy.yml`](.circleci/test-deploy.yml)). It generates a signing key, then builds a package that copies a prebuilt binary into a signed APK for the machine's own architecture.

```yaml
jobs:
  build-apks:
    machine:
      image: ubuntu-2404:current
    resource_class: arm.medium # or medium for amd64
    steps:
      - checkout
      - melange/install
      - run:
          name: Generate Signing Key
          command: melange keygen # writes melange.rsa and melange.rsa.pub
      - run:
          name: Build APKs
          command: |
            melange build melange.yaml \
              --runner docker \
              --arch "$(uname -m)" \
              --signing-key melange.rsa \
              --source-dir dist \
              --out-dir packages
```

- `--arch "$(uname -m)"` builds only for the machine's own architecture. Without it, melange builds every architecture the package supports, and building for foreign architectures needs emulation.
- Packages are written to `packages/<arch>/` (`x86_64` or `aarch64`) along with an `APKINDEX.tar.gz` signed by `melange.rsa`. apko can then use the directory as a local repository, with `melange.rsa.pub` as the trusted key.
- A key generated per job is fine when apko consumes the packages in the same pipeline. Keep a persistent key if you publish the packages.

### Choosing a Runner

`melange build` runs each package's pipeline in an isolated build environment created by a *runner*. Results on CircleCI's `ubuntu-2404:current` machine images (amd64 `medium` and arm64 `arm.medium`):

| Runner | Result | Setup |
|---|---|---|
| `docker` (recommended) | Works on amd64 and arm64 | None. The `circleci` user can already use the machine's Docker daemon. No images are pulled; melange builds the build environment locally. |
| `bubblewrap` (melange's default on Linux) | Works on amd64 and arm64 after setup | Requires `sudo`: install `bubblewrap`, and allow it to create user namespaces. Without the second step it fails with `bwrap: setting up uid map: Permission denied`, because Ubuntu 24.04's AppArmor restricts unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns = 1`). See [`tests/smoke/setup_bubblewrap.sh`](tests/smoke/setup_bubblewrap.sh). |
| `qemu` | Not usable | Needs `/dev/kvm`, which machine executors don't provide. |

Pass `--runner` explicitly. If it is omitted on Linux, melange tries `bubblewrap` and fails unless the setup above has been done.

The Docker executor is not covered by these tests and isn't recommended for `melange build`. The `docker` runner needs a local Docker daemon: `setup_remote_docker` runs the daemon on a separate host that can't mount the job's files. The `bubblewrap` runner needs to create user namespaces inside the job's container.
