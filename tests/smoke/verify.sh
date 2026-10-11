#!/bin/bash

# Verifies the output of the melange build smoke test: a signed APK for the
# machine's own architecture, in a signed repository index, containing the
# prebuilt binary unchanged.
#
# Usage: verify.sh <packages-dir> <prebuilt-binary> <public-key>

set -euo pipefail

PACKAGES_DIR=$1
PREBUILT_BINARY=$2
PUBLIC_KEY=$3

# melange names its output directories after the APK architecture, which
# matches `uname -m` on Linux (x86_64 or aarch64).
ARCH=$(uname -m)
APK="${PACKAGES_DIR}/${ARCH}/hello-prebuilt-0.0.1-r0.apk"
INDEX="${PACKAGES_DIR}/${ARCH}/APKINDEX.tar.gz"
SIGNATURE=".SIGN.RSA256.$(basename "${PUBLIC_KEY}")"

# APKs carry PAX headers that GNU tar does not recognize; it warns about them
# on stderr but still reads the archive.
list() { tar -tzf "$1" 2> /dev/null; }
require_line() {
    local line=$1 description=$2
    if ! grep -qFx "${line}"; then
        echo "ERROR: ${description} is missing '${line}'"
        exit 1
    fi
}

echo "Checking that only the ${ARCH} architecture was built..."
BUILT_ARCHES=$(ls "${PACKAGES_DIR}")
if [[ "${BUILT_ARCHES}" != "${ARCH}" ]]; then
    echo "ERROR: expected only ${ARCH} in ${PACKAGES_DIR}, found: ${BUILT_ARCHES}"
    exit 1
fi

# Archive listings are read into variables rather than piped into grep -q, which
# exits on the first match and would kill tar with SIGPIPE under pipefail.
echo "Checking that the APK and the index are signed with $(basename "${PUBLIC_KEY}")..."
APK_FILES=$(list "${APK}")
INDEX_FILES=$(list "${INDEX}")
require_line "${SIGNATURE}" "${APK}" <<< "${APK_FILES}"
require_line "${SIGNATURE}" "${INDEX}" <<< "${INDEX_FILES}"

echo "Checking that the index lists the package for ${ARCH}..."
APKINDEX=$(tar -xzOf "${INDEX}" APKINDEX 2> /dev/null)
require_line "P:hello-prebuilt" "APKINDEX" <<< "${APKINDEX}"
require_line "A:${ARCH}" "APKINDEX" <<< "${APKINDEX}"

echo "Checking that the APK contains the prebuilt binary, unchanged..."
EXPECTED=$(sha256sum < "${PREBUILT_BINARY}")
ACTUAL=$(tar -xzOf "${APK}" usr/bin/hello 2> /dev/null | sha256sum)
if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
    echo "ERROR: usr/bin/hello in the APK does not match ${PREBUILT_BINARY}"
    exit 1
fi

echo "Smoke test passed: $(basename "${APK}") is a signed ${ARCH} package."
