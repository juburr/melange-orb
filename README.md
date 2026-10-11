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
  - `release-assets.githubusercontent.com` and `objects.githubusercontent.com`: GitHub redirects release downloads from `github.com` to one of these hosts, so the download fails if they are blocked. Allow both; GitHub currently uses `release-assets.githubusercontent.com` and previously used `objects.githubusercontent.com`.
- Additional access needed by `melange build` itself (not by this orb's `install` command) when building against the [Wolfi](https://wolfi.dev) package repository:
  - `packages.wolfi.dev`: Serves the repository's signing key (`/os/wolfi-signing.rsa.pub`), package index, and the packages that make up the build environment, such as `busybox`.
  - Builds that list other repositories or keyrings in `environment.contents`, fetch sources (`fetch`, `git-checkout`), or download anything from pipeline steps (for example `go mod download`, `npm install`, or `pip install` with a cold cache) also need the hosts those steps contact.

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
