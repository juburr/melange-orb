#!/bin/bash

# Hermetic tests for src/scripts/install.sh. No network access is needed: the
# circleci, wget, and curl commands are replaced with stubs on the PATH, and
# downloads either fail or serve a fake melange tarball.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/src/scripts/install.sh"
INSTALL_COMMAND="${REPO_ROOT}/src/commands/install.yml"

# A version that will never appear in the checksum lookup table.
UNLISTED_VERSION="0.0.0-unlisted"
# A version that is in the lookup table.
LISTED_VERSION="0.61.2"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
STUB_DIR="${WORK_DIR}/stubs"
mkdir -p "${STUB_DIR}"

# "circleci env subst" is only available on CircleCI; the inputs used here
# contain no variables, so echoing them back is equivalent.
cat > "${STUB_DIR}/circleci" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "env subst" ]] && printf '%s\n' "$3"
EOF

# Stands in for both wget and curl. Every request is recorded in DOWNLOAD_LOG.
# Downloads fail unless FAKE_DOWNLOAD=1, in which case a tarball with the same
# layout as a real melange release is written, holding a fake binary.
cat > "${STUB_DIR}/wget" <<'EOF'
#!/bin/bash
url="" out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -O|-o) out=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
echo "${url}" >> "${DOWNLOAD_LOG}"
if [[ "${FAKE_DOWNLOAD:-0}" != "1" ]]; then
    echo "stub: network access is not allowed in this test" >&2
    exit 1
fi
name=$(basename "${url}" .tar.gz)
src=$(mktemp -d)
mkdir "${src}/${name}"
printf '#!/bin/sh\necho "fake melange"\n' > "${src}/${name}/melange"
tar -czf "${out}" -C "${src}" "${name}"
rm -rf "${src}"
EOF
cp "${STUB_DIR}/wget" "${STUB_DIR}/curl"
chmod +x "${STUB_DIR}/circleci" "${STUB_DIR}/wget" "${STUB_DIR}/curl"

# Runs install.sh in a fresh directory (so there is no cached tarball) and
# captures its exit status and combined output in STATUS and OUTPUT.
run_install() {
    local verify_checksums=$1
    local version=$2
    local fake_download=${3:-0}
    CASE_DIR="$(mktemp -d "${WORK_DIR}/case.XXXXXX")"
    mkdir -p "${CASE_DIR}/bin"
    set +e
    OUTPUT=$(
        cd "${CASE_DIR}" &&
        PATH="${STUB_DIR}:${PATH}" \
        DOWNLOAD_LOG="${CASE_DIR}/downloads.log" \
        FAKE_DOWNLOAD="${fake_download}" \
        PARAM_INSTALL_PATH="${CASE_DIR}/bin" \
        PARAM_VERIFY_CHECKSUMS="${verify_checksums}" \
        PARAM_VERSION="${version}" \
        bash "${INSTALL_SCRIPT}" 2>&1
    )
    STATUS=$?
    set -e
}

FAILURES=0
pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1"
    while IFS= read -r line; do echo "    | ${line}"; done <<< "${OUTPUT:-}"
    FAILURES=$((FAILURES + 1))
}
installed() { [[ -x "${CASE_DIR}/bin/melange" ]]; }
downloaded() { [[ -s "${CASE_DIR}/downloads.log" ]]; }

# Read the default of the verify_checksums parameter from the orb source, so
# these tests follow the real default rather than a copy of it.
DEFAULT_VERIFY_CHECKSUMS=$(awk '
    /^  verify_checksums:/ { in_param = 1; next }
    in_param && /^  [a-z_]+:/ { in_param = 0 }
    in_param && $1 == "default:" { print $2; exit }
' "${INSTALL_COMMAND}")
if [[ -z "${DEFAULT_VERIFY_CHECKSUMS}" ]]; then
    echo "FAIL: could not read the verify_checksums default from ${INSTALL_COMMAND}"
    exit 1
fi
echo "verify_checksums default: ${DEFAULT_VERIFY_CHECKSUMS}"

test_unlisted_version_fails_by_default() {
    local name="an unlisted version fails by default, before downloading anything"
    run_install "${DEFAULT_VERIFY_CHECKSUMS}" "${UNLISTED_VERSION}" 1
    if [[ ${STATUS} -eq 0 ]]; then fail "${name} (install succeeded)"
    elif ! grep -qF "No checksum available for version ${UNLISTED_VERSION}" <<< "${OUTPUT}"; then fail "${name} (wrong error)"
    elif downloaded; then fail "${name} (a download was attempted)"
    elif installed; then fail "${name} (a binary was installed)"
    else pass "${name}"
    fi
}

test_unlisted_version_installs_with_known_versions() {
    local name="an unlisted version installs unverified when verify_checksums is known_versions"
    run_install known_versions "${UNLISTED_VERSION}" 1
    if [[ ${STATUS} -ne 0 ]]; then fail "${name} (install failed)"
    elif ! grep -qF "WARN: No checksum available for version ${UNLISTED_VERSION}" <<< "${OUTPUT}"; then fail "${name} (no warning)"
    elif ! installed; then fail "${name} (no binary installed)"
    else pass "${name}"
    fi
}

test_unlisted_version_installs_with_verification_disabled() {
    local name="an unlisted version installs unverified when verify_checksums is false"
    run_install false "${UNLISTED_VERSION}" 1
    if [[ ${STATUS} -ne 0 ]]; then fail "${name} (install failed)"
    elif ! grep -qF "WARN: Checksum validation is disabled" <<< "${OUTPUT}"; then fail "${name} (no warning)"
    elif ! installed; then fail "${name} (no binary installed)"
    else pass "${name}"
    fi
}

test_listed_version_with_bad_binary_fails() {
    local name="a listed version fails when the binary does not match its checksum"
    run_install "${DEFAULT_VERIFY_CHECKSUMS}" "${LISTED_VERSION}" 1
    if [[ ${STATUS} -eq 0 ]]; then fail "${name} (install succeeded)"
    elif ! grep -qF "ERROR: Checksum verification failed!" <<< "${OUTPUT}"; then fail "${name} (wrong error)"
    elif installed; then fail "${name} (a binary was installed)"
    else pass "${name}"
    fi
}

test_unlisted_version_fails_by_default
test_unlisted_version_installs_with_known_versions
test_unlisted_version_installs_with_verification_disabled
test_listed_version_with_bad_binary_fails

if [[ ${FAILURES} -gt 0 ]]; then
    echo "${FAILURES} test(s) failed."
    exit 1
fi
echo "All tests passed."
