#!/usr/bin/env bash
#
# Tests for src/scripts/setup_bubblewrap.sh, run offline. The setup_bubblewrap
# command:
#
#   - uses a bwrap that already works as is, without root
#   - installs a missing bwrap with apt-get, dnf, yum, zypper or apk, through
#     sudo -n when the job's user isn't root and directly when it is
#   - carries on when apt-get update fails, but fails when the install does
#   - fails clearly without root, or without a package manager it knows
#   - loads an AppArmor profile for bwrap's real path only when AppArmor
#     restricts unprivileged user namespaces, bwrap fails, and AppArmor's
#     interface is there to load it through (a container sees the host's
#     restriction but has no interface), and refuses a path it can't write
#     into the profile safely
#   - checks bwrap with the namespaces and mounts melange's runner uses, and
#     explains a failure: containers, an old bwrap, user namespaces turned off
#   - refuses to run anywhere but Linux
#
# sudo, the package managers, bwrap, apparmor_parser, id and uname are
# stubbed, and a copy of the script reads kernel settings, AppArmor's
# interface and container markers from a fake root, so nothing on this
# machine is changed.
#
# Run from a checkout:
#   bash PATH_TO_THIS_FILE

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SETUP_SH="${ROOT}/src/scripts/setup_bubblewrap.sh"
SETUP_YML="${ROOT}/src/commands/setup_bubblewrap.yml"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
BASE="${WORK}/base"
CASE="${WORK}/case"
FAKE="${CASE}/fake"
LOG="${WORK}/calls.log"
PROFILE="${WORK}/profile"
mkdir -p "${STUBS}" "${BASE}"

FAILURES=0
OUTPUT=""
RC=0

begin() {
    echo "--- $1"
}

check() {
    local description=$1
    shift
    if "$@"; then
        echo "  ok: ${description}"
    else
        echo "  FAIL: ${description}"
        while IFS= read -r line; do
            echo "    | ${line}"
        done <<< "${OUTPUT}"$'\n'"calls:"$'\n'"$(cat "${LOG}" 2> /dev/null)"
        FAILURES=$((FAILURES + 1))
    fi
}

output_has() { [[ "${OUTPUT}" == *"$1"* ]]; }
output_lacks() { [[ "${OUTPUT}" != *"$1"* ]]; }
called() { grep -qFx -- "$1" "${LOG}"; }
called_like() { grep -qF -- "$1" "${LOG}"; }
not_called_like() { ! grep -qF -- "$1" "${LOG}"; }
rc_is() { [[ "${RC}" -eq "$1" ]]; }
sudo_always_n() { ! grep '^sudo ' "${LOG}" | grep -qv '^sudo -n '; }
profile_has() { grep -qFx -- "$1" "${PROFILE}"; }

# The script, reading /proc/sys, AppArmor's interface and the container
# markers from FAKE.
SCRIPT="${WORK}/setup_bubblewrap.sh"
sed -e "s#\"/proc/sys/#\"${FAKE}/proc/sys/#" \
    -e "s#-d /sys/kernel/security/apparmor#-d ${FAKE}/sys/kernel/security/apparmor#" \
    -e "s#-f /\\.dockerenv#-f ${FAKE}/.dockerenv#" \
    -e "s#-f /run/\\.containerenv#-f ${FAKE}/run/.containerenv#" \
    "${SETUP_SH}" > "${SCRIPT}"
for path in "${FAKE}/proc/sys/" "${FAKE}/sys/kernel/security/apparmor" "${FAKE}/.dockerenv" "${FAKE}/run/.containerenv"; do
    if ! grep -qF -- "${path}" "${SCRIPT}"; then
        echo "FAIL: could not point the test copy of setup_bubblewrap.sh at ${path}"
        exit 1
    fi
done

# The only real commands the script and the stubs may run, so the machine's
# own package managers, sudo and bwrap are never reached.
for tool in bash env readlink cat cp true; do
    ln -s "$(type -P "${tool}")" "${BASE}/${tool}"
done

cat > "${STUBS}/id" << 'EOF'
#!/usr/bin/env bash
case "$*" in
    -u) echo "${FAKE_UID}" ;;
    -un) echo "${FAKE_USER}" ;;
    *) echo "id stub: unexpected arguments: $*" >&2; exit 1 ;;
esac
EOF
cat > "${STUBS}/uname" << 'EOF'
#!/usr/bin/env bash
case "$*" in
    -s) echo "${FAKE_OS:-Linux}" ;;
    *) echo "uname stub: unexpected arguments: $*" >&2; exit 1 ;;
esac
EOF
# sudo must never be able to prompt for a password, so every call needs -n.
cat > "${WORK}/sudo" << 'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "${LOG}"
if [[ "${1:-}" != "-n" ]]; then
    echo "sudo stub: called without -n, so it could prompt for a password" >&2
    exit 2
fi
shift
if [[ -n "${SUDO_NEEDS_PASSWORD:-}" ]]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
exec "$@"
EOF
# Every package manager: logs its arguments, and installs the bwrap stub into
# INSTALL_DIR when asked for bubblewrap.
cat > "${WORK}/package-manager" << 'EOF'
#!/usr/bin/env bash
name=${0##*/}
echo "${name} $* (DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-})" >> "${LOG}"
if [[ "$*" == *update* && -n "${UPDATE_FAILS:-}" ]]; then
    echo "E: Failed to fetch a third-party repository" >&2
    exit 100
fi
if [[ "$*" == *bubblewrap* ]]; then
    if [[ -n "${INSTALL_FAILS:-}" ]]; then
        echo "E: Unable to locate package bubblewrap" >&2
        exit 100
    fi
    cp "${BWRAP_STUB}" "${INSTALL_DIR}/bwrap"
fi
EOF
# BWRAP_MODE: works, apparmor (fails until the profile is loaded), container
# or old.
cat > "${WORK}/bwrap" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--version" ]]; then
    echo "bubblewrap 0.9.0"
    exit 0
fi
echo "bwrap $*" >> "${LOG}"
case "${BWRAP_MODE:-works}" in
    works) ;;
    apparmor)
        if [[ ! -f "${PROFILE_LOADED}" ]]; then
            echo "bwrap: setting up uid map: Permission denied" >&2
            exit 1
        fi
        ;;
    container)
        echo "bwrap: No permissions to create new namespace, likely because the kernel does not allow non-privileged user namespaces." >&2
        exit 1
        ;;
    old)
        echo "bwrap: Unknown option --clearenv" >&2
        exit 1
        ;;
esac
EOF
cat > "${STUBS}/apparmor_parser" << 'EOF'
#!/usr/bin/env bash
echo "apparmor_parser $*" >> "${LOG}"
cat > "${PROFILE}"
if [[ -n "${APPARMOR_FAILS:-}" ]]; then
    echo "apparmor_parser: Unable to replace the profile. Permission denied" >&2
    exit 1
fi
: > "${PROFILE_LOADED}"
EOF
chmod +x "${STUBS}"/* "${WORK}/sudo" "${WORK}/package-manager" "${WORK}/bwrap"

# new_case NAME: starts a case on a machine with sudo, no package manager,
# no bwrap, and no kernel settings or container markers.
new_case() {
    begin "$1"
    rm -rf "${CASE}" "${PROFILE}"
    mkdir -p "${CASE}/installed" "${CASE}/pm" "${CASE}/sudo" "${FAKE}/proc/sys/kernel" "${FAKE}/proc/sys/user" "${FAKE}/run"
    cp "${WORK}/sudo" "${CASE}/sudo/sudo"
    : > "${LOG}"
}
with_pm() { ln -s "${WORK}/package-manager" "${CASE}/pm/$1"; }
with_bwrap() { cp "${WORK}/bwrap" "${CASE}/installed/bwrap"; }
without_sudo() { rm -f "${CASE}/sudo/sudo"; }
set_sysctl() { printf '%s\n' "$2" > "${FAKE}/proc/sys/${1//.//}"; }
# restrict_userns: AppArmor restricts unprivileged user namespaces, on a
# machine where profiles can be loaded, such as a machine executor.
restrict_userns() {
    set_sysctl kernel.apparmor_restrict_unprivileged_userns 1
    mkdir -p "${FAKE}/sys/kernel/security/apparmor"
}

# run [VAR=value...]: runs the script as a user other than root, with only
# the stubs and BASE on the PATH. (Bash 4.0 takes an empty "$@" for an
# unbound variable, so the assignments are copied only when there are some.)
run() {
    local -a vars=()
    if [[ $# -gt 0 ]]; then
        vars=("$@")
    fi
    OUTPUT=$(cd "${WORK}" && env -i \
        PATH="${CASE}/installed:${CASE}/pm:${CASE}/sudo:${STUBS}:${BASE}" \
        LOG="${LOG}" PROFILE="${PROFILE}" PROFILE_LOADED="${CASE}/profile-loaded" \
        BWRAP_STUB="${WORK}/bwrap" INSTALL_DIR="${CASE}/installed" \
        FAKE_UID=1001 FAKE_USER=circleci ${vars[@]+"${vars[@]}"} bash "${SCRIPT}" 2>&1)
    RC=$?
}

begin "command"
check "setup_bubblewrap.yml runs setup_bubblewrap.sh" grep -qF '<< include(scripts/setup_bubblewrap.sh) >>' "${SETUP_YML}"

new_case "a bwrap that already works is used as is"
with_bwrap
without_sudo
run
check "succeeds" rc_is 0
check "reports bwrap ready" output_has "bubblewrap 0.9.0 is ready for melange build --runner bubblewrap."
check "needs no root" not_called_like "sudo"
check "loads no AppArmor profile" not_called_like "apparmor_parser"
check "checks the namespaces melange's runner uses" called_like "bwrap --unshare-user --unshare-pid --die-with-parent --ro-bind / / --dev /dev --proc /proc --clearenv true"

new_case "a missing bwrap is installed with apt-get through sudo -n"
with_pm apt-get
run
check "succeeds" rc_is 0
check "updates the package lists" called "apt-get -qq update (DEBIAN_FRONTEND=)"
check "installs bubblewrap without prompts" called "apt-get -qq install -y --no-install-recommends bubblewrap (DEBIAN_FRONTEND=noninteractive)"
check "never lets sudo prompt" sudo_always_n
check "runs apt-get through sudo -n" called "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends bubblewrap"
check "doesn't warn" output_lacks "WARN:"
check "reports bwrap ready" output_has "is ready for melange build --runner bubblewrap."

new_case "a failing apt-get update doesn't stop the install"
with_pm apt-get
run UPDATE_FAILS=1
check "succeeds" rc_is 0
check "warns on stderr" output_has "WARN: apt-get update failed."
check "still installs bubblewrap" called_like "apt-get -qq install -y --no-install-recommends bubblewrap"

new_case "a failed install fails the step"
with_pm apt-get
run INSTALL_FAILS=1
check "fails" rc_is 100
check "shows the package manager's error" output_has "Unable to locate package bubblewrap"
check "doesn't report bwrap ready" output_lacks "is ready"

new_case "root installs without sudo"
with_pm apt-get
without_sudo
run FAKE_UID=0 FAKE_USER=root
check "succeeds" rc_is 0
check "runs apt-get directly" called "apt-get -qq install -y --no-install-recommends bubblewrap (DEBIAN_FRONTEND=noninteractive)"
check "doesn't use sudo" not_called_like "sudo"

for pm in "dnf:dnf install -y -q bubblewrap" "yum:yum install -y -q bubblewrap" \
    "zypper:zypper --non-interactive --quiet install bubblewrap" "apk:apk add --no-cache --quiet bubblewrap"; do
    new_case "a missing bwrap is installed with ${pm%%:*}"
    with_pm "${pm%%:*}"
    run
    check "succeeds" rc_is 0
    check "runs ${pm#*:}" called "${pm#*:} (DEBIAN_FRONTEND=)"
done

new_case "apt-get is preferred when there are several package managers"
with_pm apt-get
with_pm dnf
run
check "succeeds" rc_is 0
check "uses apt-get" called_like "apt-get -qq install"
check "doesn't use dnf" not_called_like "dnf "

new_case "no known package manager"
run
check "fails" rc_is 1
check "says to install bubblewrap first" output_has "ERROR: bwrap is not installed, and this system has none of the package managers"

new_case "sudo that needs a password"
with_pm apt-get
run SUDO_NEEDS_PASSWORD=1
check "fails" rc_is 1
check "says root is needed" output_has "ERROR: Setting up bubblewrap needs root to install bubblewrap, but this job runs as circleci, which can't use sudo without a password."
check "runs no package manager" not_called_like "apt-get"

new_case "no sudo, not root"
with_pm apt-get
without_sudo
run
check "fails" rc_is 1
check "says root is needed" output_has "ERROR: Setting up bubblewrap needs root to install bubblewrap"
check "runs no package manager" not_called_like "apt-get"

new_case "AppArmor restricts user namespaces"
with_bwrap
restrict_userns
run BWRAP_MODE=apparmor
check "succeeds" rc_is 0
check "loads the profile through sudo -n" called "sudo -n apparmor_parser -r"
check "profile uses the AppArmor 4 ABI" profile_has "abi <abi/4.0>,"
check "profile is named after bwrap's path and attaches to it" profile_has "profile melange-orb-bwrap-userns${CASE}/installed/bwrap ${CASE}/installed/bwrap flags=(unconfined) {"
check "profile allows user namespaces" profile_has "  userns,"
check "reports bwrap ready" output_has "is ready for melange build --runner bubblewrap."

new_case "AppArmor profile names bwrap's real path, not a symlink"
mkdir -p "${CASE}/real_bin"
cp "${WORK}/bwrap" "${CASE}/real_bin/bwrap"
ln -s "${CASE}/real_bin/bwrap" "${CASE}/installed/bwrap"
restrict_userns
run BWRAP_MODE=apparmor
check "succeeds" rc_is 0
check "profile is named after the real path and attaches to it" profile_has "profile melange-orb-bwrap-userns${CASE}/real_bin/bwrap ${CASE}/real_bin/bwrap flags=(unconfined) {"

new_case "a newly installed bwrap gets the AppArmor profile too"
with_pm apt-get
restrict_userns
run BWRAP_MODE=apparmor
check "succeeds" rc_is 0
check "installs bubblewrap" called_like "apt-get -qq install"
check "loads the profile" called "sudo -n apparmor_parser -r"

new_case "no AppArmor profile when AppArmor doesn't restrict user namespaces"
with_bwrap
set_sysctl kernel.apparmor_restrict_unprivileged_userns 0
run BWRAP_MODE=apparmor
check "fails" rc_is 1
check "loads no AppArmor profile" not_called_like "apparmor_parser"
check "says bwrap can't create namespaces" output_has "ERROR: bwrap can't create the namespaces melange's bubblewrap runner needs, as circleci."
check "shows bwrap's output" output_has "  bwrap: setting up uid map: Permission denied"
check "doesn't blame AppArmor" output_lacks "AppArmor restricts"

for blocker in "user.max_user_namespaces=0:container" "kernel.unprivileged_userns_clone=0:container" "old bwrap:old"; do
    new_case "no AppArmor profile when bwrap fails for another reason: ${blocker%%:*}"
    with_bwrap
    restrict_userns
    if [[ "${blocker}" == *=* ]]; then
        setting=${blocker%%:*}
        set_sysctl "${setting%=*}" "${setting#*=}"
    fi
    run BWRAP_MODE="${blocker#*:}"
    check "fails" rc_is 1
    check "loads no AppArmor profile" not_called_like "apparmor_parser"
    check "says bwrap can't create namespaces" output_has "ERROR: bwrap can't create the namespaces melange's bubblewrap runner needs, as circleci."
done

new_case "a profile that can't be loaded fails the step"
with_bwrap
restrict_userns
run BWRAP_MODE=apparmor APPARMOR_FAILS=1
check "fails" rc_is 1
check "says the profile wasn't loaded" output_has "ERROR: Could not load the AppArmor profile"

new_case "the AppArmor profile needs root"
with_bwrap
without_sudo
restrict_userns
run BWRAP_MODE=apparmor
check "fails" rc_is 1
check "says root is needed" output_has "ERROR: Setting up bubblewrap needs root to allow bwrap to create user namespaces"
check "loads no AppArmor profile" not_called_like "apparmor_parser"

new_case "a bwrap path that can't go into a profile is refused"
mkdir -p "${CASE}/odd dir"
cp "${WORK}/bwrap" "${CASE}/odd dir/bwrap"
restrict_userns
OUTPUT=$(cd "${WORK}" && env -i \
    PATH="${CASE}/odd dir:${CASE}/sudo:${STUBS}:${BASE}" \
    LOG="${LOG}" PROFILE="${PROFILE}" PROFILE_LOADED="${CASE}/profile-loaded" \
    FAKE_UID=1001 FAKE_USER=circleci BWRAP_MODE=apparmor bash "${SCRIPT}" 2>&1)
RC=$?
check "fails" rc_is 1
check "says why" output_has "ERROR: Can't write an AppArmor profile for bwrap at '${CASE}/odd dir/bwrap'."
check "loads no AppArmor profile" not_called_like "apparmor_parser"

new_case "a container that sees the host's AppArmor restriction loads no profile"
with_pm apt-get
set_sysctl kernel.apparmor_restrict_unprivileged_userns 1
: > "${FAKE}/.dockerenv"
run BWRAP_MODE=container
check "fails" rc_is 1
check "installs bubblewrap" called_like "apt-get -qq install"
check "loads no AppArmor profile" not_called_like "apparmor_parser"
check "says bwrap can't create namespaces" output_has "ERROR: bwrap can't create the namespaces melange's bubblewrap runner needs, as circleci."
check "says no profile can be loaded here" output_has "AppArmor restricts unprivileged user namespaces on this kernel, but /sys/kernel/security/apparmor is missing"
check "says it runs in a container" output_has "This job runs inside a container."
check "points to a machine executor" output_has "Run melange build on a machine executor."

new_case "a container is named in the error"
with_bwrap
: > "${FAKE}/.dockerenv"
run BWRAP_MODE=container
check "fails" rc_is 1
check "shows bwrap's output" output_has "  bwrap: No permissions to create new namespace"
check "says it runs in a container" output_has "This job runs inside a container."
check "points to a machine executor" output_has "Run melange build on a machine executor."

new_case "a Podman container is named in the error"
with_bwrap
: > "${FAKE}/run/.containerenv"
run BWRAP_MODE=container
check "fails" rc_is 1
check "says it runs in a container" output_has "This job runs inside a container."

new_case "no container is named outside one"
with_bwrap
run BWRAP_MODE=container
check "fails" rc_is 1
check "doesn't claim a container" output_lacks "This job runs inside a container."

new_case "an old bwrap is named in the error"
with_bwrap
run BWRAP_MODE=old
check "fails" rc_is 1
check "says bwrap is too old" output_has "This bwrap (bubblewrap 0.9.0) lacks an option melange's bubblewrap runner uses."

new_case "user namespaces turned off are named in the error"
with_bwrap
set_sysctl user.max_user_namespaces 0
set_sysctl kernel.unprivileged_userns_clone 0
run BWRAP_MODE=container
check "fails" rc_is 1
check "names user.max_user_namespaces" output_has "user.max_user_namespaces is 0"
check "names kernel.unprivileged_userns_clone" output_has "kernel.unprivileged_userns_clone is 0"

new_case "only Linux is supported"
with_pm apt-get
run FAKE_OS=Darwin
check "fails" rc_is 1
check "says why" output_has "ERROR: bubblewrap runs on Linux only, but this machine runs Darwin."
check "installs nothing" not_called_like "apt-get"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All setup_bubblewrap checks passed."
