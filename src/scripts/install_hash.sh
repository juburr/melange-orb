#!/bin/bash

# Convenience script, not used by directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh. Prints one table entry per supported architecture.

set -e
set +o history

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
cd "${WORK_DIR}"

BASE_URL="https://github.com/chainguard-dev/melange/releases/download/v${VERSION}"

# Melange publishes SHA-256 checksums of its release tarballs. Use them to make
# sure each download is intact before hashing the binary inside it.
wget "${BASE_URL}/checksums.txt" -O checksums.txt -q

# Download each architecture's tarball and get the SHA-512 checksum of the
# melange binary inside. Suppress output for readability; this is a dev
# script, so simply re-enable output if you need to debug anything.
for ARCH in amd64 arm64; do
    ASSET="melange_${VERSION}_linux_${ARCH}"
    wget "${BASE_URL}/${ASSET}.tar.gz" -O "${ASSET}.tar.gz" -q
    if ! awk -v file="${ASSET}.tar.gz" '$2 == file' checksums.txt | sha256sum --check --status; then
        echo "ERROR: ${ASSET}.tar.gz does not match the SHA-256 checksum in checksums.txt." >&2
        exit 1
    fi
    tar zxf "${ASSET}.tar.gz" "${ASSET}/melange" --strip 1
    CHECKSUM=$(sha512sum melange | awk '{ print $1 }')
    echo "[\"${VERSION}_${ARCH}\"]=\"${CHECKSUM}\""
    rm melange
done
