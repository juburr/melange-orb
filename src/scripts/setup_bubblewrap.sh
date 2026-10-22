#!/bin/bash
#
# Prepares this machine for melange's bubblewrap runner, for the
# setup_bubblewrap command:
#
#   1. installs bubblewrap (bwrap) with the system package manager, unless
#      it is already on the PATH;
#   2. when bwrap can't create a user namespace because AppArmor restricts
#      unprivileged ones, as on Ubuntu 23.10 and newer
#      (kernel.apparmor_restrict_unprivileged_userns=1), loads an AppArmor
#      profile that allows them for bwrap only. Without it, bwrap fails with
#      "setting up uid map: Permission denied". See
#      https://github.com/chainguard-dev/melange/issues/1508.
#   3. checks, as this job's user, that bwrap can create the namespaces and
#      mounts melange's bubblewrap runner uses.
#
# Nothing is changed when bwrap already works. Changes need root, so they run
# through sudo when this job's user isn't root, and sudo is never allowed to
# prompt for a password.

set -euo pipefail

info() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# as_root COMMAND...: runs COMMAND as root.
as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# require_root WHAT: fails, saying it needs root to do WHAT, unless as_root
# can run commands.
require_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if command -v sudo > /dev/null 2>&1 && sudo -n true > /dev/null 2>&1; then
        return 0
    fi
    die "Setting up bubblewrap needs root to $1, but this job runs as $(id -un), which can't use sudo without a password." \
        "Use a machine executor, or an image with bubblewrap installed and allowed to create user namespaces."
}

# sysctl_value NAME: prints the kernel setting NAME, such as
# user.max_user_namespaces, or nothing when this kernel doesn't have it.
sysctl_value() {
    local file="/proc/sys/${1//./\/}"
    if [[ -r "${file}" ]]; then
        printf '%s\n' "$(< "${file}")"
    fi
}

# bwrap_works: runs bwrap the way melange's bubblewrap runner does, in new
# user and PID namespaces with fresh /dev and /proc mounts, and leaves what
# it printed in BWRAP_OUTPUT.
bwrap_works() {
    BWRAP_OUTPUT=$(bwrap --unshare-user --unshare-pid --die-with-parent --ro-bind / / \
        --dev /dev --proc /proc --clearenv true 2>&1)
}

install_bwrap() {
    require_root "install bubblewrap"
    info "bwrap is not installed. Installing bubblewrap..."
    if command -v apt-get > /dev/null 2>&1; then
        # A third-party repository that fails to update shouldn't stop the
        # install, which may still find bubblewrap in the existing lists.
        if ! as_root apt-get -qq update; then
            warn "apt-get update failed. Trying to install bubblewrap from the package lists already on this machine."
        fi
        as_root env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends bubblewrap
    elif command -v dnf > /dev/null 2>&1; then
        as_root dnf install -y -q bubblewrap
    elif command -v yum > /dev/null 2>&1; then
        as_root yum install -y -q bubblewrap
    elif command -v zypper > /dev/null 2>&1; then
        as_root zypper --non-interactive --quiet install bubblewrap
    elif command -v apk > /dev/null 2>&1; then
        as_root apk add --no-cache --quiet bubblewrap
    else
        die "bwrap is not installed, and this system has none of the package managers this command uses" \
            "(apt-get, dnf, yum, zypper or apk). Install bubblewrap in an earlier step."
    fi
    if ! command -v bwrap > /dev/null 2>&1; then
        die "bubblewrap was installed, but bwrap is not on the PATH."
    fi
}

# allow_userns: loads an AppArmor profile that lets the bwrap on the PATH
# create user namespaces. The profile names the binary's real path, since
# AppArmor matches the file that runs, not a symlink to it. It is loaded
# from stdin, so nothing is written to /etc/apparmor.d, and it lasts until
# the machine reboots.
allow_userns() {
    local bwrap_path
    require_root "allow bwrap to create user namespaces"
    bwrap_path=$(readlink -f "$(command -v bwrap)")
    # The path is written into the profile, so only plain path characters
    # are accepted.
    if [[ ! "${bwrap_path}" =~ ^/[A-Za-z0-9._+/-]+$ ]]; then
        die "Can't write an AppArmor profile for bwrap at '${bwrap_path}'."
    fi
    info "AppArmor restricts unprivileged user namespaces. Allowing them for ${bwrap_path}."
    if ! printf '%s\n' \
        'abi <abi/4.0>,' \
        'include <tunables/global>' \
        '' \
        "profile melange-orb-bwrap-userns ${bwrap_path} flags=(unconfined) {" \
        '  userns,' \
        '}' | as_root apparmor_parser -r; then
        die "Could not load the AppArmor profile that allows bwrap to create user namespaces."
    fi
}

# explain_failure: prints bwrap's output and what is known to stop it.
explain_failure() {
    local line
    info "bwrap printed:"
    while IFS= read -r line; do
        info "  ${line}"
    done <<< "${BWRAP_OUTPUT}"
    if [[ "${BWRAP_OUTPUT}" == *"Unknown option"* ]]; then
        info "This bwrap ($(bwrap --version 2>&1 || true)) lacks an option melange's bubblewrap runner uses. Install a newer bubblewrap."
    fi
    if [[ "$(sysctl_value user.max_user_namespaces)" == "0" ]]; then
        info "user.max_user_namespaces is 0, which turns user namespaces off."
    fi
    if [[ "$(sysctl_value kernel.unprivileged_userns_clone)" == "0" ]]; then
        info "kernel.unprivileged_userns_clone is 0, which allows user namespaces only for root."
    fi
    if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
        info "This job runs inside a container."
    fi
    info "Unprivileged containers, such as CircleCI's Docker executor, can't create the namespaces and mounts bubblewrap needs." \
        "Run melange build on a machine executor."
}

if [[ "$(uname -s)" != "Linux" ]]; then
    die "bubblewrap runs on Linux only, but this machine runs $(uname -s)."
fi

if command -v bwrap > /dev/null 2>&1; then
    info "Found $(bwrap --version) at $(command -v bwrap)."
else
    install_bwrap
fi

if ! bwrap_works; then
    if [[ "$(sysctl_value kernel.apparmor_restrict_unprivileged_userns)" == "1" ]]; then
        allow_userns
    fi
    if ! bwrap_works; then
        printf 'ERROR: %s\n' "bwrap can't create the namespaces melange's bubblewrap runner needs, as $(id -un)." >&2
        explain_failure >&2
        exit 1
    fi
fi
info "$(bwrap --version) is ready for melange build --runner bubblewrap."
